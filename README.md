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
| Gentle | T-30 to T-15 | Every 5 min | Yellow `SHUTDOWN:Xm` |
| Aggressive | T-15 to T-5 | Every 2 min | Red blinking `SHUTDOWN:Xm` |
| Final | T-5 to T-0 | Every 1 min | Red blinking `SHUTDOWN:Xm` |
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
# For Apple ARM processors
gh release download --repo 'KTSCode/severance' --pattern 'sev_macos_arm64' --output ~/bin/sev
# For Apple Intel processors
gh release download --repo 'KTSCode/severance' --pattern 'sev_macos_x86' --output ~/bin/sev

chmod +x ~/bin/sev
```
*replace `~/bin` in the above commands with a directory in your PATH if you don't have `~/bin`*


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

## Updating

```bash
sev update
```

Checks GitHub releases for a newer version and replaces the binary
in-place. Uses only OTP stdlib for HTTPS — no external dependencies
required.

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
sev update     # update to latest release
sev version    # print current version
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

- **AGENTS.md** — shared conventions, build commands, workflow, and documentation lifecycle
- **CLAUDE.md** — Claude Code-specific configuration (MCP, hooks)
- **tidewave** — MCP server for live BEAM introspection (`.mcp.json`)
- **dialyxir** — static type analysis via Dialyzer (PLTs cached in `priv/plts/`)

Small, well-understood changes go straight to code. For anything larger:

1. **Research** — `docs/research/<feature>.md`
1. **Spec** — `docs/specs/<feature>.md`
1. **Plan** — `docs/plans/<feature>.md`
1. **Execute** — one phase at a time

## Roadmap
- Homebrew distribution
- Linux support
- Configurable escalation phases
- Per-day shutdown schedules (e.g. earlier on Fridays)

## TODO
  - Update CLAUDE.md to be agnostic and point to AGENTS.md
  - Move plans out of docs/superpowers
  - Update AGENTS.md with instructions for cleaning up docs so that old and outdated plans to live in there forever
  - Fix: I ended up with conflicts on main because the changes on main hadn't been pushed up before the new branch was created
  - Update: the workflow that I plan to use, is to add one or more new todo items to the README then call `mix todo | claude` this should commit (with a skill if available) any changes and push them up before branching off main 
- [x] `sev update` follow best practices to allow severance to update it self if a new version has been released
- [x] Fix issues from code audit (`docs/research/2026-03-30-code-audit.md`): osascript injection, crash on bad `--shutdown-time`, typos, dead code, duplicate env var parsing
- [x] add `mix tag` to take an arg `maj | min | pat` and then have it do all the necessary `gh` calls and file changes to increase the version number and initiate the release of the next version, including the change long stuff.
- [ ] `sev start` and `sev` should start the daemon in the backgroung and return (if the daemon is already running it should note that and then exit 0)
- [ ] `sev status` the user needs to be able to check:
  - if severance is running
  - if over time protocol has been enabled
  - how long until the next shutdown
  - the current severance version
  - if the need to update (this should fail gracefully if the call to get the latest version doesn't work)
- [ ] Fix GitHub Actions Warning. More info in: `docs/research/2026-04-02-gha-waring.md`
- [ ] Remove `sev stop` and all related documentation, it goes against the nature of the application, if the user really wants to stop the daemon they can kill -9 it
- [ ] add a `mix bump` task that prints out a prompt will all the information necessary or instructions on how to get the information necessary to upgrade deps and configuration of the application. I'll call it with `mix bump | claude`
- [ ] create a research doc with different ways of allowing severance to turn Do not disturb mode on the host machine
  - It would be nice to give it a script or add a function to the config that is run at the do not disturb intervals 
  - I'd like to give it access to my calendar so that I can Guarantee that it won't cause users to miss meetings 
- [ ] add log file functionality that keeps track of how long you're sev has been running, and usage of overtime protocol 
  - the log file location needs to be configurable in the config file

