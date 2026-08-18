# Configuration

## Resolved config precedence

Configuration is resolved in priority order (highest wins):

1. CLI flag: `sev --shutdown-time 17:00`
1. Environment variable: `SEVERANCE_SHUTDOWN_TIME=16:30 sev`
1. Config file: `~/.config/severance/config.exs`
1. Compiled defaults

## `:publishers` map contract

The `:publishers` key in `~/.config/severance/config.exs` is a map from
atom keys to publisher spec maps. Each spec may contain:

| Key | Type | Required | Default |
|---|---|---|---|
| `:fn` | `(Severance.Status.t() -> any())` | yes | — |
| `:interval_ms` | `non_neg_integer()` | no | `60_000` |
| `:tmux_var` | `String.t()` | no | — |
| `:setup` | `(-> any())` | no | — |
| `:teardown` | `(-> any())` | no | — |

Example with all keys:

```elixir
%{
  shutdown_time: "17:00",
  publishers: %{
    my_publisher: %{
      fn: fn status -> File.write!("/tmp/sev", "#{status.minutes_remaining}m") end,
      teardown: fn -> File.rm("/tmp/sev") end,
      interval_ms: 5_000
    }
  }
}
```

## `%Severance.Status{}` fields

The struct passed to every publisher `:fn`:

| Field | Type | Description |
|---|---|---|
| `:mode` | `:severance \| :overtime` | Current operating mode |
| `:phase` | see below | Current countdown phase |
| `:shutdown_time` | `Time.t() \| nil` | Configured shutdown time |
| `:minutes_remaining` | `integer() \| nil` | Minutes until shutdown (negative when past) |
| `:seconds_remaining` | `integer() \| nil` | Seconds until shutdown |
| `:version` | `String.t() \| nil` | Daemon version string |
| `:update_available?` | `boolean() \| nil` | Whether a newer release exists |
| `:log_path` | `String.t() \| nil` | Path to the activity log |

Phases in order: `:waiting`, `:gentle`, `:aggressive`, `:final`, `:shutdown`, `:done`.

## `Severance.StatusPublisher.Tmux` builder

`Severance.StatusPublisher.Tmux.publisher/3` builds a complete publisher
spec that writes to a tmux user variable:

```elixir
Severance.StatusPublisher.Tmux.publisher("countdown", fn status ->
  color = Severance.StatusPublisher.Tmux.Format.color_for_phase(status.phase)
  "#[fg=#{color},bold] sev:#{status.minutes_remaining}m #[default]"
end)
```

This is equivalent to a spec with `:fn`, `:teardown`, `:tmux_var`, and
`:interval_ms` set. Pass `interval_ms:` as a keyword option to override
the default 60-second tick.

Low-level primitives for direct use:

- `Severance.StatusPublisher.Tmux.set_var/2` — writes `@sev_<var>` via the system adapter
- `Severance.StatusPublisher.Tmux.clear_var/1` — sets `@sev_<var>` to empty string

## `Severance.StatusPublisher.Tmux.Format` helpers

`color_for_phase/2` returns a tmux 256-color name for the given phase.
The palette is a 3-element list ordered `[waiting/gentle, aggressive, final/shutdown/done]`.
Default palette: `["colour51", "colour226", "colour196"]`.

```elixir
color_for_phase(:waiting)              # "colour51"
color_for_phase(:aggressive)           # "colour226"
color_for_phase(:final)                # "colour196"
color_for_phase(:final, ["a", "b", "c"])  # "c"
```

`blink_for_phase/1` returns `",blink"` for `:aggressive` and `:final`,
empty string otherwise. Append to a tmux format attribute string:

```elixir
"#[fg=#{color}#{blink_for_phase(phase)},bold]"
```

## `:tmux_var` semantics and the tmux.conf paste block

Writing to a tmux user variable is the publisher `:fn`'s job — `:tmux_var`
does not trigger it. The `:fn` performs the write by calling
`Severance.StatusPublisher.Tmux.set_var/2` (the `publisher/2` builder wires
this for you); a bare `:fn` that only returns a string writes nothing.

`:tmux_var` is metadata: `sev init` and `sev status` read it to detect
whether `~/.tmux.conf` already references `@sev_<var>` and surface the
paste block / wiring warning when it doesn't. It causes no write on its own.

A publisher that writes `@sev_<var>` should declare a matching `:tmux_var`
so that wiring detection works. To display the value, add a reference to
your `~/.tmux.conf`:

```
set -g status-right-length 80
set -ag status-right "#{@sev_countdown}"
```

Then reload: `tmux source-file ~/.tmux.conf`.

Set `TMUX_CONF` in your environment to point to a non-default config path.
`sev init` and `sev status` both honor this variable.

## `sev init` and `sev init --with-tmux`

`sev init` creates `~/.config/severance/config.exs` with `publishers: %{}`
if the file doesn't exist, generates the LaunchAgent plist, and prints the
tmux.conf paste block for any configured publishers with `:tmux_var` that
are not yet referenced in your tmux.conf.

`sev init --with-tmux` does the same but seeds the config with the inline
`tmux_countdown` publisher. If the config already exists, it warns and
skips the write. Re-run after removing the existing config to regenerate.

## Non-tmux examples

Write status to a file for polybar or similar:

```elixir
publishers: %{
  polybar: %{
    fn: fn status ->
      File.write!("/tmp/sev_status", "sev:#{status.minutes_remaining}m")
    end,
    teardown: fn -> File.rm("/tmp/sev_status") end,
    interval_ms: 30_000
  }
}
```

Send a desktop notification on each tick:

```elixir
publishers: %{
  notify: %{
    fn: fn status ->
      System.cmd("osascript", [
        "-e",
        "display notification \"#{status.minutes_remaining}m remaining\" with title \"Severance\""
      ])
    end,
    interval_ms: 300_000
  }
}
```

## `sev status` wiring and error blocks

Plain `sev status` prints the standard status block. When publishers are
configured, two optional blocks may follow:

**tmux wiring block** — printed when at least one publisher declares
`:tmux_var` and the corresponding reference is missing from tmux.conf.
Silent when all vars are wired or no publisher uses `:tmux_var`.

```
tmux:
  @sev_countdown NOT in ~/.tmux.conf
```

**publisher errors block** — printed when the daemon is running and at
least one publisher has recorded a recent error. Shows the most recent
error per publisher.

```
publisher errors (current config):
  tmux_countdown: publish {:crash, %RuntimeError{...}} (last at 17:03:12)
```

Debug invocations:

- `sev status <publisher-name>` — invokes the publisher fn once and
  returns immediately. Useful for testing your formatter.
- `sev status <publisher-name> --teardown` — invokes the teardown fn.
  Use to manually clear a stale tmux variable.
- `sev status --teardown` (no name) — prints an error; a name is required.

## Worker lifecycle

On start, each worker runs `:teardown` (clearing stale sink state from a
prior crash), then `:setup`. The `:fn` fires immediately on the first
`:publish` tick, which is scheduled at `:interval_ms` after init.

On clean shutdown, the worker calls `:teardown` in `terminate/2`. This
clears the tmux user variable so a stale value doesn't linger.

**SIGKILL caveat**: if the daemon is killed with SIGKILL, `terminate/2`
does not run and the teardown is skipped. The tmux user variable will
hold its last written value until the next daemon restart, at which
point init-time teardown clears it.

`sev reload` runs this same teardown-then-setup lifecycle for every
worker, without restarting the daemon: a publisher removed from config
gets its `:teardown` run as its worker is torn down, and every publisher
present after the reload (new or unchanged) starts fresh — `:teardown`
then `:setup` — as if the daemon had just booted.
