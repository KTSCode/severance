# Severance

An Elixir OTP daemon that enforces a hard daily computer shutdown with
escalating warnings. Named after the show where innies don't get a choice
about when work ends.

## Why

Time blindness and hyperfocus make it genuinely difficult to stop working.
A notification you can dismiss isn't a boundary — it's a suggestion.
Severance makes the default path "your computer turns off" and forces you
to consciously opt out if you need to keep working.

## How It Works

Severance runs as a background daemon starting at login. At T-30 before
the configured shutdown time (default 4:30 PM), it begins an escalating
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
SEVERANCE_SHUTDOWN_TIME=17:00 sev
```

Or pass it as a flag (when starting manually):

```bash
sev --shutdown-time 17:00
```

Default: `16:30` (4:30 PM).

## TODO

- [ ] Use [Burrito](https://github.com/burrito-elixir/burrito) to compile to a single standalone binary

## Requirements

- Elixir 1.19+ / OTP 28+
- macOS (uses `osascript` for notifications and shutdown)
- tmux (for status bar and stale pane detection)
