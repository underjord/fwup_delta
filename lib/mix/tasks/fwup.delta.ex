defmodule Mix.Tasks.Fwup.Delta do
  use Mix.Task

  @shortdoc "Generate fwup delta between two firmware versions."

  @moduledoc """
  Generate fwup delta between two firmware versions.

  Usage:
    mix fwup.delta <old_fw> <new_fw>

  Example:
    mix fwup.delta my_old.fw my_new.fw
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    case argv do
      [source, target] ->
        {:ok, %{filepath: filepath}} = FwupDelta.generate({:local, source}, {:local, target})
        Mix.shell().info("Delta file generated at #{filepath}")

      _ ->
        Mix.shell().error("""
        Invalid arguments, needs source and target firmware file paths.
        """)

        exit({:shutdown, 1})
    end
  end
end
