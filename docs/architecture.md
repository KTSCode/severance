# Architecture

A current-state map of how Severance fits together. Unlike the dated,
point-in-time design docs under [`docs/specs/`](specs/), this file tracks
the live system and is updated as the code changes.

Severance is a background daemon that enforces a hard daily computer
shutdown with escalating warnings. It runs as a macOS LaunchAgent, drives
notifications and shutdown through `osascript`, integrates with tmux for a
status-bar countdown, and exposes an overtime opt-out over distributed
Erlang RPC.

## Entry points

A single binary is both the daemon and the CLI. `Severance.Application.start/2`
([`lib/severance/application.ex`](../lib/severance/application.ex)) picks a
path on boot:

- Running as a packaged Burrito binary with CLI arguments — parse the
  argv and `dispatch/1` the command (`sev status`, `sev otp`, `sev init`,
  `sev update`, …), then `System.halt/1`.
- Otherwise (dev/test, or `sev` with no command) — start the daemon
  supervision tree in-process.

`sev` with no subcommand spawns a detached background daemon via
`CLI.start_background/2`; `sev --daemon` runs the tree in the foreground.

## Process model

The daemon supervises two children, one-for-one:

```
Severance.Supervisor (one_for_one)
├── Severance.Countdown                       GenServer — the shutdown state machine
└── Severance.StatusPublisher.Supervisor      Supervisor (one_for_one)
    ├── Registry                               name registry for workers
    └── Severance.StatusPublisher.Worker …     one GenServer per configured publisher
```

- `Countdown` ([`lib/severance/countdown.ex`](../lib/severance/countdown.ex))
  owns all timing and shutdown behavior.
- `StatusPublisher.Supervisor`
  ([`lib/severance/status_publisher/supervisor.ex`](../lib/severance/status_publisher/supervisor.ex))
  starts a `Registry` plus one `Worker` per entry in the resolved
  `:publishers` config. A crashing publisher is isolated to its own worker
  and does not affect siblings or the countdown.

## Countdown state machine

`Countdown` moves through phases as the configured shutdown time
approaches:

```
waiting → gentle → aggressive → final → shutdown | overtime → done
```

- On `init`, it schedules a wake-up for T-30 (polling once per minute
  until then) and a separate timer for the next local midnight.
- At T-30 it enters `gentle` and begins ticking. Each `:tick` recomputes
  the phase from minutes-remaining (`Severance.Phase.phase_for_remaining/1`),
  sends a notification, and re-schedules the next tick at the phase's
  cadence (`Severance.Phase.interval_ms/1`).
- At T-15 (entering `aggressive`) it checks tmux for panes idle past the
  stale threshold and notifies for each.
- At T-0 (`shutdown`), in severance mode it notifies, calls
  `Severance.System.shutdown_machine/0`, and keeps retrying once per
  minute. In overtime mode it fires a notification burst instead.
- Weekends: `effective_mode/1` forces overtime regardless of the stored
  mode, so the machine never shuts down — you get the burst instead.
- Midnight reset: overtime is a single-day opt-out. The midnight timer
  resets the session to a fresh severance day once the local date
  advances, re-arming the next day's shutdown.

### Phases as a single source of truth

`Severance.Phase` ([`lib/severance/phase.ex`](../lib/severance/phase.ex))
is the one place that defines the escalating phases. Each phase carries
its threshold (minutes-remaining lower bound), tick cadence, notification
sound, tmux color, and blink. Consumers read from it rather than each
holding a parallel copy:

| Consumer | Reads |
|---|---|
| `Countdown` | `phase_for_remaining/1`, `interval_ms/1` |
| `Notifier` | `sound/1` |
| `StatusPublisher.Tmux.Format` | `color/2`, `blink?/1` |
| `Status` | `name/0` (the `phase` type) |

Adding or re-ordering a phase is a one-place edit here. This sets up the
roadmap item "Configurable escalation phases": the static phase list is
the seam a config-driven version would replace.

`:waiting`, `:shutdown`, and `:done` are not part of the escalating
sequence proper — they have a status color but no tick cadence or sound.

## Configuration

Configuration is resolved in `Application.resolve_config/2`, layering
sources lowest-to-highest:

1. Compiled defaults (`config/config.exs`)
1. User config file (`~/.config/severance/config.exs`)
1. `SEVERANCE_SHUTDOWN_TIME` environment variable
1. `--shutdown-time` CLI flag

The user config file is **executed as Elixir code** via `Code.eval_file/1`
(`Severance.Config`, [`lib/severance/config.ex`](../lib/severance/config.ex)) —
it is not parsed as inert data. Publisher entries are functions defined in
that file, so it must live in a directory you control.

## RPC seam

The daemon registers as `severance@localhost` (short names) with EPMD,
starting both EPMD and BEAM distribution itself
(`Application.ensure_distribution/0`) because Burrito's launcher never sets
`RELEASE_DISTRIBUTION`/`RELEASE_NODE`.

CLI commands that talk to a running daemon (`sev otp`, `sev status`, and
the `daemon_running?/0` readiness check) connect over distributed Erlang
in `CLI.with_daemon_rpc/2`:

1. Start a temporary node `severance_cli_<rand>@localhost`.
1. Set the cookie to `Node.get_cookie/0` — the cookie baked into the
   release, shared by both sides because the CLI and daemon are the same
   binary.
1. `Node.connect/1` to `severance@localhost`, then `:rpc.call/4` into
   `Severance.Countdown`.

## System adapter (test seam)

All OS interaction — notifications, shutdown, tmux commands — goes through
the `Severance.System` behaviour
([`lib/severance/system.ex`](../lib/severance/system.ex)). `adapter/0`
returns the module configured under `:severance, :system_adapter`,
defaulting to `Severance.System.Real` (`osascript` + tmux CLI). Tests
configure `Severance.System.Test`, which records calls to the test process
mailbox instead of touching the machine. Nothing in the daemon shells out
directly; it always goes through the adapter.

## Status publishers

Publishers run on the daemon and push status snapshots
(`Severance.Status`) to a sink — a tmux user variable, a polybar file, etc.
Each is a map in the user config with a formatter function and an interval.
`sev init --with-tmux` seeds a tmux countdown publisher. See
[`docs/configuration.md`](configuration.md) for the full publisher
contract.

## Module map

| Module | Responsibility |
|---|---|
| `Severance.Application` | Boot; dispatch CLI commands or start the tree; config resolution; distribution setup |
| `Severance.CLI` | Argument parsing, daemon lifecycle, RPC plumbing, status/usage output |
| `Severance.Countdown` | Shutdown state machine (phases, midnight reset, weekend, overtime) |
| `Severance.Phase` | Single source of truth for per-phase attributes |
| `Severance.Config` | Read/write the user config file |
| `Severance.Notifier` | Build and send macOS notifications per phase/mode |
| `Severance.Status` | Daemon-state snapshot passed to publishers and `sev status` |
| `Severance.ActivityLog` | Append-only session/overtime event log |
| `Severance.Init` | First-run setup: config, LaunchAgent plist, tmux instructions |
| `Severance.Updater` | Self-update from GitHub releases (OTP stdlib only) |
| `Severance.System` (+ `Real`/`Test`) | OS interaction behaviour and adapters |
| `Severance.StatusPublisher.*` | Publisher supervision, workers, and tmux helpers |

## Known rough edges

Documented here so they are visible; not fixed in this pass.

- **Config resolution leaks through Application env.** `resolve_config/2`
  writes resolved values (`:publishers`, `:overtime_notifications`,
  `:log_file`) into Application env as a side effect, and `Countdown` /
  `Worker` read them back piecemeal. There is no single runtime struct
  that represents the effective config.
- **RPC/distribution setup is duplicated.** The daemon
  (`Application.ensure_distribution/0`) and the CLI's connect path
  (`CLI.with_daemon_rpc/2`) each independently know about node naming,
  EPMD, cookies, and short names.
- **`Severance.CLI` is a large module** (~880 lines) carrying many
  responsibilities — argument parsing, daemon lifecycle, RPC plumbing,
  status formatting, publisher debugging, and usage text. Splitting it
  along those seams would make each piece independently testable.
