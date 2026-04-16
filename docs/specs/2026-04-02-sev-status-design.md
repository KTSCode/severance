# sev status

Show the user whether severance is running, overtime status, time until
shutdown, current version, and whether an update is available.

## Public API Changes

### `Severance.CLI`

- `parse_args(["status" | _rest])` returns `:status`
- `run_status/0` — connects via RPC, gathers daemon + update info, formats output
- `format_status/2` — pure function that builds the output string from a daemon
  result and an update result

### `Severance.Countdown`

- `status/0` — single `GenServer.call` returning:
  ```elixir
  %{
    mode: :severance | :overtime,
    phase: :waiting | :gentle | :aggressive | :final | :shutdown | :done,
    shutdown_time: Time.t(),
    minutes_remaining: integer()
  }
  ```

### `Severance.Updater`

- `fetch_latest_version/1` — fetches the latest release from GitHub.
  Returns `{:ok, version}` or `{:error, reason}`. Accepts `http_get:`
  option for testability.

### `Severance.Application`

- `dispatch(:status)` — calls `CLI.run_status/0`, halts with exit code

## Output Format

Running, no update:
```
Severance v0.3.0
Status:     running
Overtime:   inactive
Shutdown:   17:00 (42m remaining)
Update:     up to date
```

Running, overtime active, update available:
```
Severance v0.3.0
Status:     running
Overtime:   active
Shutdown:   17:00 (42m remaining)
Update:     v0.4.0 available (run `sev update`)
```

Running, past shutdown:
```
Severance v0.3.0
Status:     running
Overtime:   active
Shutdown:   17:00 (passed)
Update:     up to date
```

Not running, up to date:
```
Severance v0.3.0
Status:     not running
Update:     up to date
```

Not running, update check failed:
```
Severance v0.3.0
Status:     not running
Update:     unknown (check failed)
```

## Flow

1. `sev status` dispatches to `CLI.run_status/0`
2. CLI connects via RPC to the daemon node
3. On success: calls `Countdown.status/0` and `Updater.current_version/0`
   on the remote node, passes both results to `format_status/2`
4. On failure: calls `Updater.fetch_latest_version/0` locally, prints
   version header + "not running" + update status, exits 0

## Error Handling

- RPC failure: print "not running", check for updates locally, exit 0
- GitHub API failure: show "unknown (check failed)"

## Testing

- `parse_args(["status"])` — unit test returning `:status`
- `Countdown.status/0` — `start_supervised!` GenServer, assert map shape
- `Updater.fetch_latest_version/1` — injectable `http_get`, test HTTP
  success and HTTP failure paths.
- `format_status/2` — pure function, test all output variants
- `run_status/0` — returns `{:error, _}` when no daemon (same as `run_stop`)
