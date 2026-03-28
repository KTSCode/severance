# Severance — Design Spec

## Overview

Severance is an Elixir OTP application that enforces a hard daily shutdown of your
computer. It runs as a long-lived daemon (started at login via launchd), counts down
from T-30 minutes with escalating notifications, and powers off the machine at the
configured shutdown time.

An escape hatch — the Overtime Protocol (`otp`) — lets you connect to the running
BEAM node and switch to grace mode, which replaces the hard shutdown with 60 seconds
of aggressive notifications then stops.

Named after the Apple TV show where innies don't get a choice about when work ends.

## Requirements

### Daemon Behavior
- Starts at login (launchd) and via daily cron as a safety net
- Runs as a named BEAM node (`severance@<hostname>`) so the CLI can connect
- Sleeps until T-30 before the configured shutdown time (default 4:30 PM)
- Captures the current tmux `status-right` value at T-30 (when countdown begins) for later restoration
- If an instance is already running, the new invocation exits cleanly

### Countdown Phases

All times relative to configured shutdown time (default 4:30 PM):

| Phase | Window | Notification Interval | Tmux Status |
|---|---|---|---|
| Gentle | T-30 to T-15 | Every 5 minutes | Yellow `STOP:Xm` prefix |
| Aggressive | T-15 to T-5 | Every 2 minutes | Red blinking `STOP:Xm` prefix |
| Final | T-5 to T-0 | Every 1 minute | Red blinking `STOP:Xm` prefix |
| Shutdown | T-0 | Machine powers off | N/A |

### Stale Pane Detection
- At T-15, query all tmux panes for last activity time
- Report any pane with no activity in the last 15 minutes
- One macOS notification per stale pane showing `session:window` and working directory
- Purpose: remind the user to leave breadcrumb notes before shutdown

### Notifications
- macOS native notifications via `osascript`
- Escalating sound severity across phases:
  - Gentle: soft sound (e.g., "Tink")
  - Aggressive: medium sound (e.g., "Funk")
  - Final: loud sound (e.g., "Sosumi" or "Basso")
- Notification text should make it clear the machine *will* shut down

### Shutdown (`:severance` mode — default)
- At T-0, fire a final notification
- Restore the original tmux `status-right`
- Power off via `osascript -e 'tell app "System Events" to shut down'`
- **Weekdays only** — on weekends, `:severance` mode automatically behaves like
  `:overtime` (notification burst, no shutdown)

### Overtime Protocol (`:overtime` mode)
- Activated by running `severance otp` from any terminal
- The CLI starts an ephemeral BEAM node, connects to the running `severance` node,
  makes a `GenServer.call` to `Severance.Countdown` setting mode to `:overtime`
- Prints confirmation and exits
- When in overtime mode at T-0:
  - Does NOT shut down the machine
  - Fires notifications every 5 seconds for 60 seconds starting at T-0
  - Restores tmux status bar after the 60-second burst
  - Stops

### Configuration
- Shutdown time: configurable via application env / runtime config, default 4:30 PM local time
- Can be overridden at launch: `severance --shutdown-time 17:00`
- Countdown start: always T-30 relative to shutdown time
- All timing constants defined as module attributes for easy adjustment

## Architecture

### Supervision Tree

```
Severance.Application
└── Severance.Supervisor
    ├── Severance.Countdown (GenServer)
    └── (future processes if needed)
```

### Modules

**`Severance.Application`** — OTP application entry point. Parses CLI args to
determine whether to start the daemon or execute the `otp` RPC command.

**`Severance.CLI`** — Handles argument parsing and the `otp` connection logic.
When invoked with no args, starts the application normally. When invoked with `otp`,
connects to the running node and toggles overtime mode.

**`Severance.Countdown`** — GenServer that owns all countdown state and timer logic.

State:
- `mode` — `:severance` (default) or `:overtime`
- `phase` — `:waiting`, `:gentle`, `:aggressive`, `:final`, `:shutdown`, `:done`
- `shutdown_time` — the target time (e.g., ~T[16:30:00])
- `original_tmux_status` — captured at T-30 for restoration

Public API:
- `start_link/1` — starts the GenServer
- `overtime/0` — switches mode to `:overtime`, called via RPC from CLI

The GenServer uses `Process.send_after/3` to schedule phase transitions and
notification ticks. Each tick checks current time, fires the appropriate notification,
updates tmux status, and schedules the next tick.

**`Severance.Tmux`** — Tmux interaction helpers:
- `capture_status_right/0` — reads current `status-right`
- `set_countdown/3` — sets the countdown prefix with phase-appropriate styling
- `restore_status_right/1` — restores original value
- `stale_panes/1` — returns panes with last activity older than given threshold

**`Severance.Notifier`** — macOS notification helpers:
- `notify/3` — fires a notification with title, message, and sound
- `stale_pane_warning/1` — fires a notification for a stale pane

### Node Naming

The daemon starts as `severance@<hostname>` using short names (`:shortnames`).
The `otp` CLI invocation starts as `severance_cli_<random>@<hostname>`, connects
to the daemon node, makes the RPC call, then exits.

Both nodes use the same Erlang cookie (set via `rel/env.sh.eex` or
`~/.erlang.cookie`).

## Build and Deployment

### Build
- Standard Mix project with `mix release`
- Release name: `severance`
- Binary output: `~/bin/severance`

### Source Control
- Source repo: `~/severance` (standalone git repo)
- Compiled binary: `~/bin/severance` tracked by `vcsh macos`

### Launch

**launchd plist** (`~/Library/LaunchAgents/com.severance.daemon.plist`):
- Runs `~/bin/severance` at login
- `KeepAlive: false` — if it exits after shutdown, don't restart it
- `RunAtLoad: true`

**Cron** (safety net):
- Daily at a time before T-30 (e.g., 8:00 AM on weekdays)
- The daemon's single-instance check ensures no duplicate

### Deployment Workflow
1. Make changes in `~/severance`
2. `mix release`
3. Copy binary to `~/bin/severance`
4. Commit binary with `vcsh macos`

## Testing

- Unit tests for `Severance.Countdown` state machine (phase transitions, mode toggling)
- Unit tests for `Severance.Tmux.stale_panes/1` parsing logic
- Integration test for the full countdown with mocked time and mocked system commands
- No real shutdown or notification calls in tests — inject the system command layer
