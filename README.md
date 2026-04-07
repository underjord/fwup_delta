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

## Better delta performance

The Nerves documentation has a section on good settings for optimizing your firmware [for better deltas](https://hexdocs.pm/nerves/experimental-features.html#preparing-your-project). This is is the relevant config:

```
# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware,
  rootfs_overlay: "rootfs_overlay",
  mksquashfs_flags: ["-noI", "-noId", "-noD", "-noF", "-noX"]

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1596027629"
```

## Optimizations

`fwup_delta` performs at least one non-obvious optimization.

If a file resource is included in the archive but not reference in any task with a name that starts with `upgrade` we will remove the file resource. Some files are only used for the initial `complete` flash. This could only be a negative if you used file-resource to smuggle additional files that you want to extract from the archive in some custom way.

## Checking capabilities of the current fwup install

If you need to determine if a fwup_delta delta will with the version of fwup installed on a device that is best done with the `confuse` library which offers [Confuse.get_features_usage/1](https://hexdocs.pm/confuse/Confuse.Fwup.html#get_feature_usage/1) for this. The `confuse` library has various utilities for interpreting fwup.conf files and the meta.conf included in `.fw` files made by fwup. This is the mechanism used in NervesHub to determine if a delta is possible for a particular fwup config.
