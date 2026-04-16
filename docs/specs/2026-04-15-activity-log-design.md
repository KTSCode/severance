# Activity Log

Persistent, plain-text log that records daemon sessions and overtime
protocol usage.

## Log Format

One event per line, plain text, greppable:

```
2026-04-15T10:00:00 started
2026-04-15T16:45:00 overtime
2026-04-15T18:30:00 stopped duration_minutes=510
```

Three event types:

| Event | When | Payload |
|---|---|---|
| `started` | Daemon boots | none |
| `overtime` | OTP activated | none |
| `stopped` | Daemon shuts down | `duration_minutes=N` |

Duration is wall-clock minutes from the `started` event. Start time is
held in Application env (`activity_log_started_at`) during the session.

Timestamps use `NaiveDateTime.local_now/0` (or the test-injectable
`now_fn` already used by Countdown).

## Default Log Location

`~/.local/state/severance/activity.log`

Follows XDG_STATE_HOME convention for apps with config in `~/.config`.
The directory is created on first write if it doesn't exist.

## Configuration

New `log_file` key in the config map:

```elixir
%{
  shutdown_time: "17:00",
  overtime_notifications: true,
  log_file: "~/.local/state/severance/activity.log"
}
```

Stored as a string with `~`. Expanded at runtime via `Path.expand/1`.
Resolved through the same config layering as other keys (compiled
defaults < config file < env var < CLI flag), though only the config
file layer is expected to override this.

## Module: `Severance.ActivityLog`

Plain module, no GenServer. Low-frequency writer (3-4 events/day).

### Public API

- `log_started(log_file)` - appends `started` entry, stores start time
  in Application env
- `log_overtime(log_file)` - appends `overtime` entry
- `log_stopped(log_file)` - appends `stopped duration_minutes=N` entry
- `format_entry(event, opts)` - formats a single log line (pure, for
  testing)
- `default_log_file()` - returns the default path

### File I/O

Each write: `File.open/3` with `:append`, write line, close. No held
file handle. `File.mkdir_p!/1` on the parent directory before first
write.

## Integration Points

### `Severance.Config`

- Add `log_file` to `@default_config`
- Update `generate_contents/1` to include `log_file`
- `read/1` merges defaults so missing keys get the default

### `Severance.Application`

- `resolve_config/2` reads `log_file` from config, stores in Application
  env (`:log_file`)
- `start_daemon/1` calls `ActivityLog.log_started/1` after supervision
  tree starts

### `Severance.Countdown`

- `handle_call(:overtime, ...)` calls `ActivityLog.log_overtime/1`
- `terminate/2` calls `ActivityLog.log_stopped/1`

`terminate/2` fires on orderly shutdown (SIGTERM, `System.stop/0`,
supervisor restart). Does not fire on `kill -9` or power loss. A
`started` with no matching `stopped` signals abnormal termination.

### `Severance.CLI`

- New command: `sev log` - reads and prints the activity log to stdout
- `parse_args(["log" | _rest])` returns `:log`
- `dispatch(:log)` resolves config, reads the file, prints it
- If no log file exists, prints "No activity log found at <path>"
- Help text updated to include `sev log`

## Documentation

- README usage table: add `sev log` row
- README config example: add `log_file` key
- `sev init` writes `log_file` in the default config
