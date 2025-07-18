defmodule FwupDelta.NervesSystemTest do
  use ExUnit.Case, async: true

  # @supported_systems %{
  #   "nerves_system_rpi" => "https://github.com/nerves-project/nerves_system_rpi",
  #   "nerves_system_rpi0" => "https://github.com/nerves-project/nerves_system_rpi0",
  #   "nerves_system_rpi2" => "https://github.com/nerves-project/nerves_system_rpi2",
  #   "nerves_system_rpi3a" => "https://github.com/nerves-project/nerves_system_rpi3a",
  #   "nerves_system_rpi3" => "https://github.com/nerves-project/nerves_system_rpi3",
  #   "nerves_system_rpi4" => "https://github.com/nerves-project/nerves_system_rpi4",
  #   "nerves_system_rpi5" => "https://github.com/nerves-project/nerves_system_rpi5",
  #   "nerves_system_bbb" => "https://github.com/nerves-project/nerves_system_bbb",
  #   "nerves_system_x86_64" => "https://github.com/nerves-project/nerves_system_x86_64",
  #   "nerves_system_osd32mp1" => "https://github.com/nerves-project/nerves_system_osd32mp1",
  #   "nerves_system_grisp2" => "https://github.com/nerves-project/nerves_system_grisp2",
  #   "nerves_system_mangopi_mq_pro" =>
  #     "https://github.com/nerves-project/nerves_system_mangopi_mq_pro"
  # }

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
    # "grisp2",
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
    defp offsets(start, parts_with_sizes) do
      {offsets, _} =
        parts_with_sizes
        |> Enum.reduce({[], start}, fn {field, size}, {fields, offset} ->
          fields = [{field, {offset, size}} | fields]
          {fields, offset + size}
        end)

      Enum.reverse(offsets)
    end

    defp build_fw!(path, fwup_path, data_path) do
      case System.cmd("fwup", ["-c", "-f", fwup_path, "-o", path],
             stderr_to_stdout: true,
             env: [
               {"TEST_1", data_path}
             ]
           ) do
        {_, 0} ->
          path

        {output, status} ->
          flunk("Error in fwup with status #{status}:\n#{output}")
      end
    end

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

    defp mcopy(img_path, offset, files, to_dir) do
      File.mkdir_p(to_dir)

      file_args =
        files
        |> Enum.map(fn file ->
          "::#{file}"
        end)

      args = ["-i", "#{img_path}@@#{offset * 512}"] ++ file_args ++ [to_dir]
      {_output, 0} = System.cmd("mdir", ["-i", "#{img_path}@@#{offset * 512}"], env: [])

      {_, 0} =
        System.cmd("mcopy", args, env: [])
    end

    defp same_fat_files?(base_dir, {img_a, offset_a}, {img_b, offset_b}, files) do
      path_a = Path.join(base_dir, "fat_a")
      path_b = Path.join(base_dir, "fat_b")
      mcopy(img_a, offset_a, files, path_a)
      mcopy(img_b, offset_b, files, path_b)

      for file <- files do
        a = File.read!(Path.join(path_a, file))
        b = File.read!(Path.join(path_b, file))
        assert a == b
      end
    end

    defp compare_images?({img_a, offset_a, size_a}, {img_b, offset_b, size_b}) do
      # fwup uses 512 byte blocks
      offset_a = offset_a * 512
      size_a = size_a * 512
      offset_b = offset_b * 512
      size_b = size_b * 512
      data_a = File.read!(img_a)
      data_b = File.read!(img_b)
      <<_::binary-size(offset_a), d1::binary-size(size_a), _::binary>> = data_a
      <<_::binary-size(offset_b), d2::binary-size(size_b), _::binary>> = data_b
      compare_data?(d1, d2, 0, true)
    end

    defp compare_data?(
           <<chunk_1::binary-size(512), d1::binary>>,
           <<chunk_2::binary-size(512), d2::binary>>,
           offset,
           valid?
         ) do
      valid? =
        if chunk_1 != chunk_2 do
          IO.puts("Difference at offset: #{offset} (#{trunc(offset / 512)})")
          find_diff(chunk_1, chunk_2)
          false
        else
          valid?
        end

      compare_data?(d1, d2, offset + 512, valid?)
    end

    defp compare_data?(<<chunk_1::binary>>, <<chunk_2::binary>>, offset, valid?) do
      if chunk_1 != chunk_2 do
        IO.puts("Difference at final offset: #{offset} (#{trunc(offset / 512)})")
        find_diff(chunk_1, chunk_2)
        false
      else
        valid?
      end
    end

    defp find_diff(chunk_1, chunk_2, byte \\ 0) do
      case {chunk_1, chunk_2} do
        {<<b1::8, r1::binary>>, <<b2::8, r2::binary>>} when b1 == b2 ->
          find_diff(r1, r2, byte + 1)

        {<<b1::8, r1::binary>>, <<b2::8, r2::binary>>} when b1 != b2 ->
          IO.puts("#{byte} @\t\t#{h(b1)}  #{h(b2)}")
          find_diff(r1, r2, byte + 1)

        {<<>>, <<>>} ->
          :ok
      end
    end

    defp h(b), do: inspect(b, as: :binary, base: :hex)

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

  defp random_bytes(size) do
    :rand.bytes(size)
  end
end
