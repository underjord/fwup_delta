defmodule FwupDelta.NervesSystemTest do
  use ExUnit.Case, async: true

  @default_targets [
    "rpi",
    "rpi0",
    "rpi2",
    "rpi3a",
    "rpi3",
    "rpi4",
    "rpi5",
    "bbb",
    "x86_64",
    "osd32mp1",
    "grisp2",
    "mangopi_mq_pro"
  ]

  setup_all do
    with path_1 when is_binary(path_1) <- System.find_executable("mdir"),
         path_2 when is_binary(path_2) <- System.find_executable("mcopy") do
      :ok
    else
      _ ->
        flunk("Please install mtools to run these tests.")
    end

    tmp_dir = System.tmp_dir!()
    path = Path.join(tmp_dir, "fwup_delta_nerves")
    File.rm_rf(path)

    {output, status} =
      System.shell("yes | mix nerves.new fwup_delta_nerves",
        cd: tmp_dir
        # into: IO.stream()
      )

    if status != 0 do
      IO.puts("Output:")
      IO.puts(output)
      flunk("Failed to create fwup_delta_nerves project")
    end

    {:ok, %{path: path}}
  end

  describe "nerves official systems" do
    defp complete!(fw_path, image_path) do
      case System.cmd("fwup", ["-a", "-d", image_path, "-i", fw_path, "-t", "complete"],
             stderr_to_stdout: true,
             env: []
           ) do
        {_, 0} ->
          image_path

        {output, status} ->
          flunk("Error in fwup with status #{status}:\n#{output}")
      end
    end

    defp upgrade!(fw_path, image_path) do
      IO.puts("Upgrading #{image_path} using #{fw_path}")

      case System.cmd("fwup", ["-a", "-d", image_path, "-i", fw_path, "-t", "upgrade"],
             stderr_to_stdout: true,
             into: IO.stream(),
             env: []
           ) do
        {_, 0} ->
          image_path

        {output, status} ->
          flunk("Error in fwup with status #{status}:\n#{output}")
      end
    end

    defp sha256sum(path) do
      data = File.read!(path)
      :sha256 |> :crypto.hash(data) |> Base.encode64()
    end

    defp build!(path, target) do
      {output, status} =
        System.shell("mix deps.get && mix firmware",
          cd: path,
          env: [{"MIX_TARGET", target}]
          # Comment this back in to debug output while running
          # into: IO.stream()
        )

      firmware_path = Path.join(path, "_build/#{target}_dev/nerves/images/fwup_delta_nerves.fw")

      if status != 0 do
        IO.puts("Build failed with status: #{status}")
        IO.puts("Output:")
        IO.puts(output)
        flunk("Build failed")
      end

      {:ok, firmware_path}
    end

    for t <- @default_targets do
      @tag :tmp_dir
      @tag timeout: 240_000
      test "build #{t}", %{path: path, tmp_dir: dir} do
        target = unquote(t)
        IO.puts("")
        IO.puts("")
        IO.puts("==== #{target} ====")
        dir = Path.join(dir, target)
        File.mkdir_p!(dir)
        IO.puts("Building...")
        {:ok, fw_path} = build!(path, target)
        delta_path = Path.join(dir, "delta.fw")
        %{size: base_size} = File.stat!(fw_path)

        IO.puts("Generating delta...")

        {:ok,
         %{
           filepath: delta_path,
           fwup_metadata: meta,
           size: delta_size,
           source_size: ^base_size,
           target_size: ^base_size
         }} =
          FwupDelta.do_generate(fw_path, fw_path, delta_path, dir)

        IO.puts("")
        IO.puts("== General ==")

        assert %{size: ^delta_size} = File.stat!(delta_path)

        if delta_size < base_size do
          IO.puts("✅ Delta is smaller")
        else
          IO.puts("⚠️ Delta is larger")
        end

        IO.puts("Valid? #{bool(meta.valid?)}")
        IO.puts("Required fwup version: #{meta.complete_fwup_version}")
        IO.puts("Required fwup version for deltas: #{meta.delta_fwup_version}")
        IO.puts("")
        IO.puts("Encryption? #{bool(meta.encryption?)}")
        IO.puts("")
        IO.puts("== Deltas ==")
        IO.puts("FAT deltas? #{bool(meta.fat_deltas?)}")
        IO.puts("Raw deltas? #{bool(meta.raw_deltas?)}")

        IO.puts("")
        IO.puts("Applying complete task...")
        img_a = complete!(fw_path, Path.join(dir, "a.img"))
        hash_a = sha256sum(img_a)

        IO.puts("Applying upgrade task...")
        upgrade!(delta_path, img_a)
        hash_u = sha256sum(img_a)
        assert hash_a != hash_u
      end
    end
  end

  defp bool(true), do: "✅"
  defp bool(false), do: "❌"
end
