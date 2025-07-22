defmodule FwupDelta do
  @moduledoc """
  Generate delta firmware files based on input source and target firmwares.
  """

  require Logger

  @type firmware() :: {:url, String.t()} | {:local, String.t()}
  @type confirmed_path() :: String.t()

  @typedoc """
  On delta creation we get a file, we get some size information and we get any
  tool metadata that we should store about the delta archive. Maybe minimum
  required tool version for example.
  """
  @type delta_created() :: %{
          filepath: String.t(),
          size: non_neg_integer(),
          source_size: non_neg_integer(),
          target_size: non_neg_integer(),
          fwup_metadata: map()
        }

  @spec generate(firmware(), firmware()) :: {:ok, delta_created()} | {:error, term()}
  def generate(source, target) do
    dir = Path.join(System.tmp_dir!(), to_string(System.unique_integer([:positive])))
    :ok = File.mkdir_p(dir)
    output_path = Path.join(dir, "delta.fw")

    with {:ok, source_path} <- fetch(source),
         {:ok, target_path} <- fetch(target) do
      do_generate(source_path, target_path, output_path, dir)
    end
  end

  @spec do_generate(
          source_path :: String.t(),
          target_path :: String.t(),
          output_path :: String.t(),
          work_dir :: String.t()
        ) :: {:ok, delta_created()} | {:error, term()}
  def do_generate(source_path, target_path, output_path, work_dir) do
    source_work_dir = Path.join(work_dir, "source")
    target_work_dir = Path.join(work_dir, "target")
    output_work_dir = Path.join(work_dir, "output")

    with :ok <- File.mkdir_p(work_dir),
         :ok <- File.mkdir_p(source_work_dir),
         :ok <- File.mkdir_p(target_work_dir),
         :ok <- File.mkdir_p(output_work_dir),
         {:ok, %{size: source_size}} <- File.stat(source_path),
         {:ok, %{size: target_size}} <- File.stat(target_path),
         {_, 0} <- System.cmd("unzip", ["-qq", source_path, "-d", source_work_dir], env: []),
         {_, 0} <- System.cmd("unzip", ["-qq", target_path, "-d", target_work_dir], env: []),
         {:ok, source_meta_conf} <- File.read(Path.join(source_work_dir, "meta.conf")),
         {:ok, target_meta_conf} <- File.read(Path.join(target_work_dir, "meta.conf")),
         {:ok, tool_metadata} <- get_tool_metadata(Path.join(target_work_dir, "meta.conf")),
         :ok <- Confuse.Fwup.validate_delta(source_meta_conf, target_meta_conf),
         {:ok, deltas} <- Confuse.Fwup.get_delta_files(Path.join(target_work_dir, "meta.conf")),
         {:ok, all_delta_files} <- delta_files(deltas) do
      Logger.info("Generating delta for files: #{Enum.join(all_delta_files, ", ")}")

      _ =
        for absolute <- Path.wildcard(target_work_dir <> "/**"), not File.dir?(absolute) do
          path = Path.relative_to(absolute, target_work_dir)

          output_path = Path.join(output_work_dir, path)

          output_path
          |> Path.dirname()
          |> File.mkdir_p!()

          _ =
            case path do
              "meta." <> _ ->
                File.cp!(Path.join(target_work_dir, path), Path.join(output_work_dir, path))

              "data/" <> subpath ->
                if subpath in all_delta_files do
                  source_filepath = Path.join(source_work_dir, path)
                  target_filepath = Path.join(target_work_dir, path)

                  case File.stat(source_filepath) do
                    {:ok, %{size: f_source_size}} ->
                      args = [
                        "-A",
                        "-S",
                        "-f",
                        "-s",
                        source_filepath,
                        target_filepath,
                        output_path
                      ]

                      %{size: f_target_size} = File.stat!(target_filepath)

                      {_, 0} = System.cmd("xdelta3", args, stderr_to_stdout: true, env: [])
                      %{size: f_delta_size} = File.stat!(output_path)

                      Logger.info(
                        "Generated delta for #{path}, from #{Float.round(f_source_size / 1024 / 1024, 1)} MB to #{Float.round(f_target_size / 1024 / 1024, 1)} MB via delta of #{Float.round(f_delta_size / 1024 / 1024, 1)} MB"
                      )

                    {:error, :enoent} ->
                      File.cp!(target_filepath, output_path)
                  end
                else
                  File.cp!(Path.join(target_work_dir, path), Path.join(output_work_dir, path))
                end
            end
        end

      # firmware archive files order matters:
      # 1. meta.conf.ed25519 (optional)
      # 2. meta.conf
      # 3. other...
      [
        "meta.conf.*",
        "meta.conf",
        "data"
      ]
      |> Enum.each(&add_to_zip(&1, output_work_dir, output_path))

      {:ok, %{size: size}} = File.stat(output_path)

      {:ok,
       %{
         filepath: output_path,
         size: size,
         source_size: source_size,
         target_size: target_size,
         fwup_metadata: tool_metadata
       }}
    end
  end

  defp fetch({:url, url}) do
    download(url)
  end

  defp fetch({:local, local_path}) do
    case File.stat(local_path) do
      {:ok, _} ->
        {:ok, local_path}

      {:error, reason} ->
        {:error, {:local, reason}}
    end
  end

  defp download(url) do
    dir = System.tmp_dir!()
    filename = "#{System.unique_integer([:positive])}.fw"
    filepath = Path.join(dir, filename)

    case :httpc.request(
           :get,
           {url |> to_charlist, []},
           [],
           stream: filepath |> to_charlist
         ) do
      {:ok, :saved_to_file} ->
        {:ok, filepath}

      reason ->
        {:error, {:download_failed, reason}}
    end
  end

  defp get_tool_metadata(meta_conf_path) do
    with {:ok, feature_usage} <- Confuse.Fwup.get_feature_usage(meta_conf_path) do
      tool_metadata =
        for {key, value} <- Map.from_struct(feature_usage), into: %{} do
          case value do
            %Version{} ->
              {key, Version.to_string(value)}

            _ ->
              {key, value}
          end
        end

      {:ok, tool_metadata}
    end
  end

  defp delta_files(deltas) do
    deltas
    |> Enum.flat_map(fn {_k, files} ->
      files
    end)
    |> Enum.uniq()
    |> case do
      [] -> {:error, :no_delta_support_in_firmware}
      delta_files -> {:ok, delta_files}
    end
  end

  defp add_to_zip(glob, workdir, output) do
    workdir
    |> Path.join(glob)
    |> Path.wildcard()
    |> case do
      [] ->
        :ok

      paths ->
        args = ["-r", "-qq", output | Enum.map(paths, &Path.relative_to(&1, workdir))]
        {_, 0} = System.cmd("zip", args, cd: workdir, env: [])

        :ok
    end
  end
end
