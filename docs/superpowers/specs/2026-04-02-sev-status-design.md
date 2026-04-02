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

- `fetch_latest_version/1` — reads ETS cache, hits GitHub API only when
  cache is missing or older than 24 hours. Returns `{:ok, version}` or
  `{:error, reason}`. Accepts `http_get:` option for testability.

### `Severance.Application`

- `dispatch(:status)` — calls `CLI.run_status/0`, halts with exit code
- Creates ETS table `:severance_version_cache` at daemon startup (owned
  by supervisor so it survives GenServer restarts)

## ETS Cache

Table: `:severance_version_cache`, type `:set`, read/write concurrency enabled.

Single row: `{:latest_version, version_string, unix_timestamp}`.

`fetch_latest_version/1` checks the timestamp. If the entry is missing or
older than 24 hours, it fetches from GitHub, writes the result, and returns
it. On fetch failure with a stale cache, returns the stale value. On fetch
failure with no cache, returns `{:error, reason}`.

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

Not running:
```
Severance v0.3.0
Status:     not running
```

Update check failed:
```
Update:     unknown (check failed)
```

## Flow

1. `sev status` dispatches to `CLI.run_status/0`
2. CLI connects via RPC to the daemon node
3. On success: calls `Countdown.status/0` and `Updater.fetch_latest_version/0`
   on the remote node, passes both results to `format_status/2`
4. On failure: prints version header + "not running", exits 0

## Error Handling

- RPC failure: print "not running", skip daemon-dependent fields, exit 0
- GitHub API failure with fresh cache: return cached version
- GitHub API failure with no cache: show "unknown (check failed)"

## Testing

- `parse_args(["status"])` — unit test returning `:status`
- `Countdown.status/0` — `start_supervised!` GenServer, assert map shape
- `Updater.fetch_latest_version/1` — injectable `http_get`, test cache
  hit/miss/stale/fetch-error scenarios against real ETS table
- `format_status/2` — pure function, test all output variants
- `run_status/0` — returns `{:error, _}` when no daemon (same as `run_stop`)
