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

## Checking capabilities of the current fwup install

If you need to determine if a fwup_delta delta will with the version of fwup installed on a device that is best done with the `confuse` library which offers [Confuse.get_features_usage/1](https://hexdocs.pm/confuse/Confuse.Fwup.html#get_feature_usage/1) for this. The `confuse` library has various utilities for interpreting fwup.conf files and the meta.conf included in `.fw` files made by fwup. This is the mechanism used in NervesHub to determine if a delta is possible for a particular fwup config.
