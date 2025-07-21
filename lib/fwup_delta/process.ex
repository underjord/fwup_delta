defmodule FwupDelta.Process do
  defstruct work_dir: nil,
            source_path: nil,
            target_path: nil,
            output_path: nil,
            source_work_dir: nil,
            target_work_dir: nil,
            output_work_dir: nil,
            source_meta_path: nil,
            target_meta_path: nil,
            source_meta: nil,
            target_meta: nil,
            source_size: 0,
            target_size: 0,
            delta_size: 0

  @spec new(
          work_dir :: String.t(),
          source_path :: String.t(),
          target_path :: String.t(),
          output_path :: String.t()
        ) :: %__MODULE__{}
  def new(work_dir, source_path, target_path, output_path) do
    %__MODULE__{
      work_dir: work_dir,
      source_path: source_path,
      target_path: target_path,
      output_path: output_path,
      source_work_dir: Path.join(work_dir, "source"),
      target_work_dir: Path.join(work_dir, "target"),
      output_work_dir: Path.join(work_dir, "output"),
      source_meta_path: Path.join(work_dir, "source/meta.conf"),
      target_meta_path: Path.join(work_dir, "target/meta.conf")
    }
  end

  def create_work_dirs!(%__MODULE__{} = process) do
    :ok = File.mkdir_p(process.source_work_dir)
    :ok = File.mkdir_p(process.target_work_dir)
    :ok = File.mkdir_p(process.output_work_dir)
    process
  end

  def check_firmware_sizes!(%__MODULE__{} = process) do
    {:ok, source_size} = File.stat(process.source_path, :size)
    {:ok, target_size} = File.stat(process.target_path, :size)
    %{process | source_size: source_size, target_size: target_size}
  end

  def read_meta(%__MODULE__{} = process) do
    with {:ok, source_meta} <- File.read(process.source_meta_path),
         {:ok, target_meta} <- File.read(process.target_meta_path) do
      %{process | source_meta: source_meta, target_meta: target_meta}
    end
  end
end
