# FwupDelta

A library for generating [fwup](https://github.com/fwup-home/fwup) delta updates from Elixir. Fwup itself does not provide a way to generate delta updates.

This can be used as a library in Elixir code for your OTA platform, a mix task during your Nerves development or even for scripting.

This was extracted from NervesHub which had the only reference implementation of this procedure.

## Installation

Most easy to install using igniter in your project:

```
mix archive.install hex igniter_new
mix igniter.install fwup_delta
```

Or the package can be installed
by adding `fwup_delta` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fwup_delta, "~> 0.1.0"}
  ]
end
```

## Mix task

After installing the package you run:

```bash
mix fwup.delta firmware_1.fw firmware_2.fw
```

## Scripting

Assuming you have Elixir installed:

```elixir
Mix.install([:fwup_delta])

{:ok, %{filepath: delta_fw}} = FwupDelta.generate({:local, "firmware-v1.0.fw"}, {:local, "firmware-v2.0.fw"})
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/fwup_delta>.
