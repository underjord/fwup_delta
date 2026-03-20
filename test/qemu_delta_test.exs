defmodule FwupDelta.QemuDeltaTest do
  use ExUnit.Case, async: false

  @moduletag :qemu
  @moduletag timeout: 600_000

  @target "qemu_aarch64"
  @ssh_port 10022

  setup_all do
    unless System.find_executable("qemu-system-aarch64") do
      flunk("qemu-system-aarch64 not found. Please install QEMU to run these tests.")
    end

    with path_1 when is_binary(path_1) <- System.find_executable("mdir"),
         path_2 when is_binary(path_2) <- System.find_executable("mcopy") do
      :ok
    else
      _ -> flunk("Please install mtools to run these tests.")
    end

    tmp_dir = System.tmp_dir!()
    path = Path.join(tmp_dir, "fwup_delta_qemu")
    File.rm_rf(path)

    IO.puts("Creating nerves project...")

    {output, status} =
      System.shell("yes | mix nerves.new fwup_delta_qemu", cd: tmp_dir)

    if status != 0 do
      flunk("Failed to create nerves project:\n#{output}")
    end

    IO.puts("Building firmware for #{@target}...")

    {output, status} =
      System.shell("mix deps.get && mix firmware",
        cd: path,
        env: [{"MIX_TARGET", @target}]
      )

    if status != 0 do
      IO.puts(output)
      flunk("Build failed")
    end

    fw_path =
      Path.join(path, "_build/#{@target}_dev/nerves/images/fwup_delta_qemu.fw")

    bootloader =
      [System.user_home!(), ".nerves", "artifacts", "nerves_system_#{@target}-*", "images", "little_loader.elf"]
      |> Path.join()
      |> Path.wildcard()
      |> List.last()

    unless bootloader do
      flunk("little_loader.elf not found in nerves artifacts")
    end

    {:ok, %{fw_path: fw_path, bootloader: bootloader}}
  end

  @tag :tmp_dir
  test "delta upgrade completes and device reboots successfully",
       %{fw_path: fw_path, bootloader: bootloader, tmp_dir: dir} do
    IO.puts("Generating delta...")
    delta_path = Path.join(dir, "delta.fw")
    {:ok, _} = FwupDelta.do_generate(fw_path, fw_path, delta_path, dir)

    IO.puts("Creating disk image...")
    disk_path = Path.join(dir, "disk.img")

    {_, 0} =
      System.cmd("fwup", ["-a", "-i", fw_path, "-d", disk_path, "-t", "complete"],
        stderr_to_stdout: true,
        env: []
      )

    IO.puts("Starting QEMU...")
    {port, _pid} = qemu = start_qemu(bootloader, disk_path)

    try do
      IO.puts("Waiting for first boot...")
      assert wait_for_boot(port), "Device failed to boot within timeout"

      IO.puts("Waiting for SSH to become available...")
      assert wait_for_ssh(), "SSH did not become available"

      drain_output(port)

      IO.puts("Uploading delta firmware via SSH fwup subsystem...")
      {upload_output, upload_status} = upload_firmware(delta_path)
      IO.puts("SSH upload finished with status #{upload_status}")
      IO.puts("SSH output: #{String.slice(upload_output, 0..500)}")

      # After the upload, the device should reboot. QEMU may either:
      # 1. Restart the VM internally (we see a second boot on the same port)
      # 2. Exit (the port closes), in which case we restart QEMU manually
      IO.puts("Waiting for device to reboot with upgraded firmware...")

      case wait_for_reboot(port) do
        :booted ->
          IO.puts("Delta upgrade completed successfully - device rebooted and booted!")

        :qemu_exited ->
          IO.puts("QEMU exited on reboot, restarting to verify upgraded disk boots...")
          {port2, _} = qemu2 = start_qemu(bootloader, disk_path)

          try do
            assert wait_for_boot(port2), "Device failed to boot from upgraded disk"
            IO.puts("Delta upgrade completed successfully - upgraded disk boots!")
          after
            stop_qemu(qemu2)
          end
      end
    after
      stop_qemu(qemu)
    end
  end

  defp start_qemu(bootloader, disk_path) do
    {machine, cpu} = qemu_machine_config()
    qemu_path = System.find_executable("qemu-system-aarch64")

    port =
      Port.open(
        {:spawn_executable, qemu_path},
        [
          :binary,
          :stderr_to_stdout,
          :exit_status,
          args: [
            "-machine", machine,
            "-cpu", cpu,
            "-smp", "1",
            "-m", "256M",
            "-kernel", bootloader,
            "-netdev", "user,id=eth0,hostfwd=tcp:127.0.0.1:#{@ssh_port}-:22",
            "-device", "virtio-net-device,netdev=eth0,mac=fe:db:ed:de:d0:01",
            "-global", "virtio-mmio.force-legacy=false",
            "-drive", "if=none,file=#{disk_path},format=raw,id=vdisk",
            "-device", "virtio-blk-device,drive=vdisk,bus=virtio-mmio-bus.0",
            "-nographic"
          ]
        ]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    {port, pid}
  end

  defp stop_qemu({port, os_pid}) do
    Port.close(port)
    System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
  rescue
    _ ->
      System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
  catch
    _, _ -> :ok
  end

  defp wait_for_boot(port) do
    wait_for_output(port, "iex", 120_000)
  end

  # Wait for the device to either reboot (showing iex again) or QEMU to exit
  defp wait_for_reboot(port) do
    case wait_for_output_or_exit(port, "iex", 120_000) do
      {:found, _} -> :booted
      :exited -> :qemu_exited
      :timeout -> flunk("Device did not reboot within timeout")
    end
  end

  defp wait_for_output(port, marker, timeout) do
    case wait_for_output_or_exit(port, marker, timeout) do
      {:found, _} -> true
      _ -> false
    end
  end

  defp wait_for_output_or_exit(port, marker, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(port, marker, deadline, "")
  end

  defp do_wait(port, marker, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {^port, {:data, data}} ->
          output = acc <> data

          if String.contains?(output, marker) do
            {:found, output}
          else
            trimmed =
              if byte_size(output) > 10_000,
                do: binary_part(output, byte_size(output) - 10_000, 10_000),
                else: output

            do_wait(port, marker, deadline, trimmed)
          end

        {^port, {:exit_status, status}} ->
          IO.puts("QEMU exited with status #{status}")
          :exited
      after
        min(remaining, 1000) ->
          do_wait(port, marker, deadline, acc)
      end
    end
  end

  defp drain_output(port) do
    receive do
      {^port, {:data, _}} -> drain_output(port)
    after
      100 -> :ok
    end
  end

  defp upload_firmware(fw_path, attempts \\ 5)
  defp upload_firmware(_fw_path, 0), do: {"Upload failed after retries", 1}

  defp upload_firmware(fw_path, attempts) do
    Process.sleep(3_000)

    {output, status} =
      System.shell(
        "ssh -p #{@ssh_port} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 127.0.0.1 -s fwup < #{fw_path}",
        stderr_to_stdout: true
      )

    if status == 0 or attempts == 1 do
      {output, status}
    else
      IO.puts("SSH upload attempt failed (#{attempts - 1} retries left): #{String.slice(output, 0..200)}")
      upload_firmware(fw_path, attempts - 1)
    end
  end

  defp wait_for_ssh(attempts_remaining \\ 30)
  defp wait_for_ssh(0), do: false

  defp wait_for_ssh(attempts_remaining) do
    case :gen_tcp.connect(~c"127.0.0.1", @ssh_port, [], 1000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        Process.sleep(1_000)
        wait_for_ssh(attempts_remaining - 1)
    end
  end

  defp qemu_machine_config do
    arch = to_string(:erlang.system_info(:system_architecture))
    os = :os.type()

    case {arch, os} do
      {"aarch64-" <> _, {:unix, :darwin}} ->
        {"virt,accel=hvf", "host"}

      {"aarch64-" <> _, {:unix, :linux}} ->
        if System.find_executable("kvm"),
          do: {"virt,accel=kvm", "host"},
          else: {"virt", "cortex-a53"}

      _ ->
        {"virt", "cortex-a53"}
    end
  end
end
