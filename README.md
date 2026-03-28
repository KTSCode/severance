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

## Installation

### Build from source

```bash
cd ~/severance
mix deps.get
MIX_ENV=prod mix release severance
cp -r _build/prod/rel/severance ~/bin/severance
ln -sf ~/bin/severance/bin/sev ~/bin/sev
```

### Start at login

```bash
cp rel/com.severance.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.severance.daemon.plist
```

### Manual start

```bash
sev            # start the daemon
sev otp        # activate overtime protocol
sev stop       # stop the daemon
```

## Configuration

Set the shutdown time via environment variable:

```bash
SEVERANCE_SHUTDOWN_TIME=16:30 sev
```

Or pass it as a flag (when starting manually):

```bash
sev --shutdown-time 17:00
```

Default: `17:00` (5:00 PM).

## Requirements

- Elixir 1.19+ / OTP 28+
- macOS (uses `osascript` for notifications and shutdown)
- tmux (for status bar and stale pane detection)

## AI Native

This project is set up for AI-assisted development. Each coding session
starts fresh and relies on durable repo files rather than chat history.

### Tooling
- **usage_rules** — manages project-level `CLAUDE.md` with build commands and conventions
- **tidewave** — MCP server for live BEAM introspection (`.mcp.json` configures it)
- **dialyxir** — static type analysis via Dialyzer (PLTs cached in `priv/plts/`)
- **PropCheck** — property-based testing via PropEr

### Workflow for Larger Features
Small, well-understood changes go straight to code. For anything too large
or uncertain for a single pass:

1. **Research** — write a discovery note in `docs/research/<feature>.md`
   capturing why the behavior matters, code paths inspected, and decisions
   that narrowed the options.
1. **Plan** — break the research into phased implementation slices in
   `docs/plans/<feature>.md`. Each phase should be independently verifiable.
1. **Execute** — work one phase at a time. Each session reads only the
   durable files it needs, not the entire design history.

Update research or plan docs before the next pass whenever the approach
changes materially.

### Dependency Guidance
`usage_rules` syncs dependency-provided rules into `CLAUDE.md` via
`mix usage_rules.sync`. This is opt-in, project-owned guidance — not a
scaffold default. Currently no deps ship rules, so the sync is a no-op.

## TODO
- [x] Make the project AI-Native
  - [x] use `../chief/specs/001-ai-native-workflow.md` to update this file with an AI-Native section
  - [x] Install https://hexdocs.pm/usage_rules/readme.html
  - [x] Install https://hexdocs.pm/dialyxir/readme.html
  - [x] Install https://hexdocs.pm/tidewave/claude_code.html
  - [x] Install https://hexdocs.pm/propcheck/PropCheck.html
- [ ] Use [Burrito](https://github.com/burrito-elixir/burrito) to compile to a single standalone binary
- [ ] Set up CI to automatically compile burrito binaries and release them
- [ ] Set a severeance config file that goes in `~/.config/severance`
- [ ] Make config file generation automatic with defaults

