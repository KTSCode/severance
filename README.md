<p align="center">
  <img src="priv/static/logo.png" alt="Severance" width="200">
</p>

# Severance

A background application that enforces a hard daily computer shutdown with
escalating warnings. Named after the show where outies don't get a choice
about when work ends. By contrast this severance is designed to promote
better work/life balance rather than facilitate inhumane experimentation.

## Why

Time blindness and hyperfocus make it genuinely difficult to stop working.
A notification you can dismiss isn't a boundary — it's a suggestion.
Severance makes the default path "your computer turns off" and forces you
to consciously opt out if you need to keep working.

## How It Works

Severance runs as a background daemon starting at login. At T-30 before
the configured shutdown time (default 5:00 PM), it begins an escalating
countdown:

| Phase | Window | Interval | Tmux Status |
|---|---|---|---|
| Gentle | T-30 to T-15 | Every 5 min | Yellow `STOP:Xm` |
| Aggressive | T-15 to T-5 | Every 2 min | Red blinking `STOP:Xm` |
| Final | T-5 to T-0 | Every 1 min | Red blinking `STOP:Xm` |
| Shutdown | T-0 | Machine powers off | — |

At T-15, Severance checks all tmux panes for activity. Any pane idle for
15+ minutes gets a notification reminding you to leave a breadcrumb note.

On weekends, the machine never shuts down — you get the notification
burst instead.

## Overtime Protocol

If you're dealing with an incident or genuinely need to keep working,
activate the Overtime Protocol:

```bash
sev otp
```

This connects to the running daemon via BEAM RPC and switches to grace
mode. Instead of shutting down at T-0, Severance fires a notification
every 5 seconds for 60 seconds, then stops. It trusts your judgment after
that.

## Requirements

- macOS (uses `osascript` for notifications and shutdown)
- tmux (for status bar integration and stale pane detection)

## Installation

### From a GitHub release

Download the latest binary from the [releases page][releases] and place it
on your PATH:

```bash
gh release download --pattern 'sev_macos_arm64' --dir ~/bin
chmod +x ~/bin/sev
```

### From source

Requires [asdf](https://asdf-vm.com/) (manages Erlang, Elixir, and Zig)
and `xz` on PATH.

```bash
asdf install                        # installs toolchain from .tool-versions
mix deps.get
MIX_ENV=prod mix release sev
cp burrito_out/sev_macos_arm64 ~/bin/sev
chmod +x ~/bin/sev
```

[releases]: https://github.com/KTSCode/severance/releases

## Setup

```bash
sev init
```

Creates `~/.config/severance/config.exs`, generates the LaunchAgent plist,
and checks tmux readiness. Safe to re-run.

## Usage

```bash
sev            # start the daemon
sev otp        # activate overtime protocol
sev stop       # stop the daemon
```

### Start at login

```bash
cp rel/com.severance.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.severance.daemon.plist
```

## Configuration

Configuration is resolved in priority order (highest wins):

1. CLI flag: `sev --shutdown-time 17:00`
1. Environment variable: `SEVERANCE_SHUTDOWN_TIME=16:30 sev`
1. Config file: `~/.config/severance/config.exs`
1. Compiled defaults

The config file is a plain Elixir term:

```elixir
%{
  shutdown_time: "17:00",
  timezone: "America/Los_Angeles",
  overtime_notifications: true
}
```

Set `overtime_notifications: false` to disable the notification burst when
overtime is active or when starting after shutdown time.

## Development

### Dependencies

- [asdf](https://asdf-vm.com/) — installs Erlang, Elixir, and Zig from `.tool-versions`
- [gh](https://cli.github.com/) — GitHub CLI for releases and PRs
- `xz` — required by the Burrito release builder

### Getting started

```bash
asdf install
mix deps.get
mix compile --warnings-as-errors
mix test
```

### Quality checks

```bash
mix credo --strict                  # lint
mix dialyzer                        # typecheck (slow first run — builds PLT)
```

### AI-assisted workflow

This project is set up for AI-assisted development. Each coding session
starts fresh and relies on durable repo files rather than chat history.

- **CLAUDE.md** — build commands, conventions, and project context
- **tidewave** — MCP server for live BEAM introspection (`.mcp.json`)
- **dialyxir** — static type analysis via Dialyzer (PLTs cached in `priv/plts/`)

Small, well-understood changes go straight to code. For anything larger:

1. **Research** — `docs/research/<feature>.md`
1. **Plan** — `docs/plans/<feature>.md`
1. **Execute** — one phase at a time

## Roadmap
- Homebrew tap distribution
- Linux support
- Configurable escalation phases
- Per-day shutdown schedules (e.g. earlier on Fridays)

## TODO
- [ ] Add a claude skill that pulls the next item off this TODO list and goes through the claude plan mode to create a plan to do it
- [ ] figure out how to infer system timezone so it doesn't need to live in the config

