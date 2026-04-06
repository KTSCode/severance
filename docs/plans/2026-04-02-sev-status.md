# sev status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `sev status` command that shows daemon running state, overtime mode, time until shutdown, version, and cached update availability.

**Architecture:** CLI parses `status` arg, dispatches to `CLI.run_status/0` which connects to the daemon via RPC to call `Countdown.status/0` and `Updater.fetch_latest_version/0`. The ETS version cache is created at daemon startup in `Application.start_daemon/1`. A pure `CLI.format_status/2` function handles all output formatting.

**Tech Stack:** Elixir/OTP, GenServer, ETS, BEAM RPC

---

### Task 1: Create feature branch

- [ ] **Step 1: Create branch from main**

```bash
git checkout -b todo/sev_status main
```

---

### Task 2: Add `parse_args` for status

**Files:**
- Modify: `lib/severance/cli.ex:60` (add clause before other parse_args heads)
- Test: `test/severance/cli_test.exs`

- [ ] **Step 1: Write the failing test**

In `test/severance/cli_test.exs`, add inside the `describe "parse_args/1"` block:

```elixir
test "status arg returns :status" do
  assert CLI.parse_args(["status"]) == :status
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/severance/cli_test.exs --only line:XX`
(where XX is the line number of the new test)

Expected: FAIL — `status` falls through to the catch-all which returns `:start`

- [ ] **Step 3: Add parse_args clause**

In `lib/severance/cli.ex`, add this clause after the `version` clauses (line 64) and before the `otp` clause (line 65):

```elixir
def parse_args(["status" | _rest]), do: :status
```

Also update the `@type parse_args_result` (line 47-57) to include `:status`:

```elixir
@type parse_args_result ::
        :start
        | {:start, keyword()}
        | :daemon
        | {:daemon, keyword()}
        | :overtime
        | :status
        | :stop
        | :init
        | :update
        | :version
        | {:error, String.t()}
```

And update the `@moduledoc` to include `sev status`:

```elixir
@moduledoc """
Handles CLI argument parsing and the Overtime Protocol RPC connection.

## Usage

    sev                        # Start the daemon in the background
    sev start                  # Start the daemon in the background
    sev --daemon               # Run the daemon in the foreground (internal)
    sev init                   # Set up config, plist, and tmux
    sev update                 # Update to latest release
    sev version                # Print current version
    sev -v                     # Print current version
    sev status                 # Show daemon status and version info
    sev --shutdown-time HH:MM  # Start with custom shutdown time
    sev otp                    # Activate Overtime Protocol on running daemon
    sev overtime               # Activate Overtime Protocol on running daemon
    sev over_time_protocol     # Activate Overtime Protocol on running daemon
    sev stop                   # Stop the running daemon
"""
```

And update the `@doc` for `parse_args/1` to mention `:status`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/severance/cli_test.exs`

Expected: all tests PASS

- [ ] **Step 5: Format and lint**

```bash
mix format lib/severance/cli.ex test/severance/cli_test.exs
mix credo --strict
```

- [ ] **Step 6: Commit**

```bash
git add lib/severance/cli.ex test/severance/cli_test.exs
git commit -m "Parse 'status' CLI arg"
```

---

### Task 3: Add `Countdown.status/0`

**Files:**
- Modify: `lib/severance/countdown.ex:55-61` (add public API function after `mode/0`)
- Modify: `lib/severance/countdown.ex:119-122` (add handle_call clause after `:mode`)
- Test: `test/severance/countdown_test.exs`

- [ ] **Step 1: Write the failing test**

In `test/severance/countdown_test.exs`, add a new describe block:

```elixir
describe "status/0" do
  test "returns status map with mode, phase, shutdown_time, and minutes_remaining" do
    start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})

    status = Countdown.status()

    assert status.mode == :severance
    assert status.phase == :waiting
    assert status.shutdown_time == ~T[23:59:59]
    assert is_integer(status.minutes_remaining)
  end

  test "reflects overtime mode" do
    start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})
    Countdown.overtime()

    status = Countdown.status()

    assert status.mode == :overtime
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/severance/countdown_test.exs --only line:XX`

Expected: FAIL — `Countdown.status/0` is undefined

- [ ] **Step 3: Implement `status/0`**

In `lib/severance/countdown.ex`, add after the `mode/0` function (after line 61):

```elixir
@doc """
Returns status information for the running daemon.

Includes mode, phase, configured shutdown time, and minutes remaining.
"""
@spec status() :: %{
        mode: :severance | :overtime,
        phase: :waiting | :gentle | :aggressive | :final | :shutdown | :done,
        shutdown_time: Time.t(),
        minutes_remaining: integer()
      }
def status do
  GenServer.call(__MODULE__, :status)
end
```

Add `handle_call` clause after the `:mode` handler (after line 122):

```elixir
@impl true
def handle_call(:status, _from, state) do
  status = %{
    mode: state.mode,
    phase: state.phase,
    shutdown_time: state.shutdown_time,
    minutes_remaining: minutes_remaining(state.shutdown_time)
  }

  {:reply, status, state}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/severance/countdown_test.exs`

Expected: all tests PASS

- [ ] **Step 5: Format and lint**

```bash
mix format lib/severance/countdown.ex test/severance/countdown_test.exs
mix credo --strict
```

- [ ] **Step 6: Commit**

```bash
git add lib/severance/countdown.ex test/severance/countdown_test.exs
git commit -m "Add Countdown.status/0"
```

---

### Task 4: Add `Updater.fetch_latest_version/1` with ETS cache

**Files:**
- Modify: `lib/severance/updater.ex` (add `create_cache_table/0`, `fetch_latest_version/1`)
- Test: `test/severance/updater_test.exs`

The `api_url/0` and `decode_json/1` functions in Updater are currently private. They need to stay private — `fetch_latest_version/1` will call them internally.

- [ ] **Step 1: Write failing tests**

In `test/severance/updater_test.exs`, add a new describe block:

```elixir
describe "fetch_latest_version/1" do
  setup do
    # Create a fresh ETS table for each test
    table = :severance_version_cache

    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    else
      :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    end

    on_exit(fn ->
      if :ets.whereis(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end)

    :ok
  end

  test "fetches from GitHub and caches result" do
    current = Updater.current_version()

    http_get = fn _url ->
      body = :json.encode(%{"tag_name" => "v99.0.0", "assets" => []})
      {:ok, IO.iodata_to_binary(body)}
    end

    assert {:ok, "99.0.0"} = Updater.fetch_latest_version(http_get: http_get)

    # Verify it's cached
    [{:latest_version, "99.0.0", _ts}] = :ets.lookup(:severance_version_cache, :latest_version)
  end

  test "returns cached version when cache is fresh" do
    now = System.system_time(:second)
    :ets.insert(:severance_version_cache, {:latest_version, "1.2.3", now})

    http_get = fn _url -> raise "should not be called" end

    assert {:ok, "1.2.3"} = Updater.fetch_latest_version(http_get: http_get)
  end

  test "fetches fresh when cache is stale (older than 24h)" do
    stale_ts = System.system_time(:second) - 25 * 60 * 60
    :ets.insert(:severance_version_cache, {:latest_version, "1.0.0", stale_ts})

    http_get = fn _url ->
      body = :json.encode(%{"tag_name" => "v2.0.0", "assets" => []})
      {:ok, IO.iodata_to_binary(body)}
    end

    assert {:ok, "2.0.0"} = Updater.fetch_latest_version(http_get: http_get)
  end

  test "returns stale cache on fetch failure" do
    stale_ts = System.system_time(:second) - 25 * 60 * 60
    :ets.insert(:severance_version_cache, {:latest_version, "1.0.0", stale_ts})

    http_get = fn _url -> {:error, :nxdomain} end

    assert {:ok, "1.0.0"} = Updater.fetch_latest_version(http_get: http_get)
  end

  test "returns error on fetch failure with no cache" do
    http_get = fn _url -> {:error, :nxdomain} end

    assert {:error, :nxdomain} = Updater.fetch_latest_version(http_get: http_get)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/severance/updater_test.exs --only line:XX`

Expected: FAIL — `Updater.fetch_latest_version/1` is undefined

- [ ] **Step 3: Implement `create_cache_table/0` and `fetch_latest_version/1`**

In `lib/severance/updater.ex`, add the module attribute after the existing `@repo` (line 25):

```elixir
@cache_table :severance_version_cache
@cache_ttl_seconds 24 * 60 * 60
```

Add after `current_version/0` (after line 36):

```elixir
@doc """
Creates the ETS table for caching the latest version.

Called once at daemon startup. Safe to call multiple times — returns
`:already_exists` if the table exists.
"""
@spec create_cache_table() :: :ok | :already_exists
def create_cache_table do
  if :ets.whereis(@cache_table) != :undefined do
    :already_exists
  else
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  end
end

@doc """
Returns the latest available version, using a 24-hour ETS cache.

Checks the cache first. If the cache is missing or older than 24 hours,
fetches from the GitHub Releases API. On fetch failure with a stale
cache, returns the stale value. On fetch failure with no cache, returns
the error.

Accepts `http_get:` option for testability.
"""
@spec fetch_latest_version(keyword()) :: {:ok, String.t()} | {:error, term()}
def fetch_latest_version(opts \\ []) do
  now = System.system_time(:second)

  case read_cache(now) do
    {:ok, version} ->
      {:ok, version}

    :miss ->
      http_get = Keyword.get(opts, :http_get, &default_http_get/1)
      fetch_and_cache(http_get, now)

    {:stale, version} ->
      http_get = Keyword.get(opts, :http_get, &default_http_get/1)

      case fetch_and_cache(http_get, now) do
        {:ok, new_version} -> {:ok, new_version}
        {:error, _reason} -> {:ok, version}
      end
  end
end

@spec read_cache(integer()) :: {:ok, String.t()} | {:stale, String.t()} | :miss
defp read_cache(now) do
  if :ets.whereis(@cache_table) == :undefined do
    :miss
  else
    case :ets.lookup(@cache_table, :latest_version) do
      [{:latest_version, version, ts}] when now - ts < @cache_ttl_seconds ->
        {:ok, version}

      [{:latest_version, version, _ts}] ->
        {:stale, version}

      [] ->
        :miss
    end
  end
end

@spec fetch_and_cache((String.t() -> {:ok, binary()} | {:error, term()}), integer()) ::
        {:ok, String.t()} | {:error, term()}
defp fetch_and_cache(http_get, now) do
  with {:ok, body} <- http_get.(api_url()),
       {:ok, release} <- decode_json(body),
       {:ok, version} <- extract_version(release) do
    if :ets.whereis(@cache_table) != :undefined do
      :ets.insert(@cache_table, {:latest_version, version, now})
    end

    {:ok, version}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/severance/updater_test.exs`

Expected: all tests PASS

- [ ] **Step 5: Format and lint**

```bash
mix format lib/severance/updater.ex test/severance/updater_test.exs
mix credo --strict
```

- [ ] **Step 6: Commit**

```bash
git add lib/severance/updater.ex test/severance/updater_test.exs
git commit -m "Add Updater.fetch_latest_version with ETS cache"
```

---

### Task 5: Create ETS table at daemon startup

**Files:**
- Modify: `lib/severance/application.ex:165-177` (inside `start_daemon/1`)

- [ ] **Step 1: Add ETS table creation**

In `lib/severance/application.ex`, inside `start_daemon/1`, add the table creation call before starting the supervisor. After `start_children = ...` (line 167) and before `children = ...` (line 169):

```elixir
Severance.Updater.create_cache_table()
```

The full function becomes:

```elixir
@spec start_daemon(keyword()) :: {:ok, pid()}
def start_daemon(opts \\ []) do
  config = resolve_config(opts)
  start_children = Application.get_env(:severance, :start_children, true)
  Severance.Updater.create_cache_table()

  children =
    if start_children do
      [{Severance.Countdown, shutdown_time: config.shutdown_time}]
    else
      []
    end

  sup_opts = [strategy: :one_for_one, name: Severance.Supervisor]
  Supervisor.start_link(children, sup_opts)
end
```

- [ ] **Step 2: Verify existing tests still pass**

Run: `mix test`

Expected: all tests PASS

- [ ] **Step 3: Format and lint**

```bash
mix format lib/severance/application.ex
mix credo --strict
```

- [ ] **Step 4: Commit**

```bash
git add lib/severance/application.ex
git commit -m "Create ETS version cache at daemon startup"
```

---

### Task 6: Add `CLI.format_status/2` pure function

**Files:**
- Modify: `lib/severance/cli.ex` (add `format_status/2`)
- Test: `test/severance/cli_test.exs`

- [ ] **Step 1: Write failing tests**

In `test/severance/cli_test.exs`, add a new describe block:

```elixir
describe "format_status/2" do
  test "formats running daemon with no update" do
    daemon = %{
      mode: :severance,
      phase: :waiting,
      shutdown_time: ~T[17:00:00],
      minutes_remaining: 42
    }

    update = {:ok, Severance.Updater.current_version()}

    output = CLI.format_status({:ok, daemon}, update)

    assert output =~ "Severance v#{Severance.Updater.current_version()}"
    assert output =~ "Status:     running"
    assert output =~ "Overtime:   inactive"
    assert output =~ "Shutdown:   17:00 (42m remaining)"
    assert output =~ "Update:     up to date"
  end

  test "formats running daemon with overtime active" do
    daemon = %{
      mode: :overtime,
      phase: :aggressive,
      shutdown_time: ~T[17:00:00],
      minutes_remaining: 10
    }

    update = {:ok, Severance.Updater.current_version()}

    output = CLI.format_status({:ok, daemon}, update)

    assert output =~ "Overtime:   active"
  end

  test "formats running daemon with update available" do
    daemon = %{
      mode: :severance,
      phase: :waiting,
      shutdown_time: ~T[17:00:00],
      minutes_remaining: 42
    }

    update = {:ok, "99.0.0"}

    output = CLI.format_status({:ok, daemon}, update)

    assert output =~ "Update:     v99.0.0 available (run `sev update`)"
  end

  test "formats passed shutdown time" do
    daemon = %{
      mode: :overtime,
      phase: :done,
      shutdown_time: ~T[17:00:00],
      minutes_remaining: -30
    }

    update = {:ok, Severance.Updater.current_version()}

    output = CLI.format_status({:ok, daemon}, update)

    assert output =~ "Shutdown:   17:00 (passed)"
  end

  test "formats daemon not running" do
    output = CLI.format_status({:error, "connection failed"}, {:error, :skip})

    assert output =~ "Severance v#{Severance.Updater.current_version()}"
    assert output =~ "Status:     not running"
    refute output =~ "Overtime:"
    refute output =~ "Shutdown:"
    refute output =~ "Update:"
  end

  test "formats update check failure" do
    daemon = %{
      mode: :severance,
      phase: :waiting,
      shutdown_time: ~T[17:00:00],
      minutes_remaining: 42
    }

    update = {:error, :nxdomain}

    output = CLI.format_status({:ok, daemon}, update)

    assert output =~ "Update:     unknown (check failed)"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/severance/cli_test.exs --only line:XX`

Expected: FAIL — `CLI.format_status/2` is undefined

- [ ] **Step 3: Implement `format_status/2`**

In `lib/severance/cli.ex`, add after `run_stop/0` (after line 230):

```elixir
@doc """
Formats status information into a human-readable string.

Takes a daemon result (`{:ok, status_map}` or `{:error, reason}`) and
an update result (`{:ok, latest_version}` or `{:error, reason}`).
"""
@spec format_status(
        {:ok, map()} | {:error, term()},
        {:ok, String.t()} | {:error, term()}
      ) :: String.t()
def format_status(daemon_result, update_result) do
  version = Severance.Updater.current_version()
  header = "Severance v#{version}"

  case daemon_result do
    {:ok, daemon} ->
      overtime = if daemon.mode == :overtime, do: "active", else: "inactive"

      shutdown =
        if daemon.minutes_remaining <= 0 do
          "#{format_time(daemon.shutdown_time)} (passed)"
        else
          "#{format_time(daemon.shutdown_time)} (#{daemon.minutes_remaining}m remaining)"
        end

      update = format_update(update_result, version)

      """
      #{header}
      Status:     running
      Overtime:   #{overtime}
      Shutdown:   #{shutdown}
      Update:     #{update}\
      """

    {:error, _reason} ->
      """
      #{header}
      Status:     not running\
      """
  end
end

@spec format_time(Time.t()) :: String.t()
defp format_time(time) do
  Calendar.strftime(time, "%H:%M")
end

@spec format_update({:ok, String.t()} | {:error, term()}, String.t()) :: String.t()
defp format_update({:ok, latest}, current) do
  case Severance.Updater.check_version(current, latest) do
    :update_available -> "v#{latest} available (run `sev update`)"
    :up_to_date -> "up to date"
  end
end

defp format_update({:error, _reason}, _current) do
  "unknown (check failed)"
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/severance/cli_test.exs`

Expected: all tests PASS

- [ ] **Step 5: Format and lint**

```bash
mix format lib/severance/cli.ex test/severance/cli_test.exs
mix credo --strict
```

- [ ] **Step 6: Commit**

```bash
git add lib/severance/cli.ex test/severance/cli_test.exs
git commit -m "Add CLI.format_status/2 pure formatting function"
```

---

### Task 7: Add `CLI.run_status/0` and wire up dispatch

**Files:**
- Modify: `lib/severance/cli.ex` (add `run_status/0`)
- Modify: `lib/severance/application.ex` (add `dispatch(:status)`)
- Test: `test/severance/cli_test.exs`

- [ ] **Step 1: Write the failing test**

In `test/severance/cli_test.exs`, add a new describe block:

```elixir
describe "run_status/0" do
  test "returns :ok with not-running output when daemon is not running" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = CLI.run_status()
      end)

    assert output =~ "not running"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/severance/cli_test.exs --only line:XX`

Expected: FAIL — `CLI.run_status/0` is undefined

- [ ] **Step 3: Implement `run_status/0`**

In `lib/severance/cli.ex`, add after `run_stop/0` and before `format_status/2`:

```elixir
@doc """
Connects to the running daemon and prints status information.

Queries the daemon for countdown status and version cache. If the daemon
is not running, prints a minimal status with the local version.

Returns `:ok` always — status is informational, not an operation that fails.
"""
@spec run_status() :: :ok
def run_status do
  daemon_result =
    with_daemon_rpc(
      fn target ->
        case :rpc.call(target, Severance.Countdown, :status, []) do
          {:badrpc, reason} -> {:error, inspect(reason)}
          status -> {:ok, status}
        end
      end,
      quiet: true
    )

  # Normalize with_daemon_rpc error shape
  daemon_result =
    case daemon_result do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end

  update_result =
    case daemon_result do
      {:ok, _} ->
        with_daemon_rpc(
          fn target ->
            case :rpc.call(target, Severance.Updater, :fetch_latest_version, []) do
              {:badrpc, reason} -> {:error, inspect(reason)}
              result -> result
            end
          end,
          quiet: true
        )

      {:error, _} ->
        {:error, :skip}
    end

  IO.puts(format_status(daemon_result, update_result))
  :ok
end
```

- [ ] **Step 4: Wire up dispatch in Application**

In `lib/severance/application.ex`, add a `dispatch(:status)` clause after `dispatch(:stop)` (after line 46):

```elixir
defp dispatch(:status) do
  Node.stop()
  CLI.run_status()
  System.halt(0)
end
```

The `Node.stop()` call is needed for the same reason as `start_or_notify/1` — the Burrito release boots as `severance@hostname` and we need to release that node name so `with_daemon_rpc` can connect to the actual daemon.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/severance/cli_test.exs`

Expected: all tests PASS

- [ ] **Step 6: Run full test suite**

Run: `mix test`

Expected: all tests PASS

- [ ] **Step 7: Format and lint**

```bash
mix format lib/severance/cli.ex lib/severance/application.ex test/severance/cli_test.exs
mix credo --strict
```

- [ ] **Step 8: Commit**

```bash
git add lib/severance/cli.ex lib/severance/application.ex test/severance/cli_test.exs
git commit -m "Add sev status command"
```

---

### Task 8: Update changelog and README

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `README.md`

- [ ] **Step 1: Update CHANGELOG.md**

Under `## [Unreleased]`, add:

```markdown
### Added
- `sev status` command showing daemon state, overtime mode, shutdown countdown, version, and update availability
- ETS-cached version check (24-hour TTL) for update availability in status output
```

- [ ] **Step 2: Update README.md usage section**

In the Usage section, add `sev status` to the command list:

```markdown
sev status     # show daemon status and version info
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md README.md
git commit -m "Document sev status in changelog and README"
```

---

### Task 9: Run dialyzer and final checks

- [ ] **Step 1: Run full test suite**

```bash
mix test
```

Expected: all tests PASS

- [ ] **Step 2: Run dialyzer**

```bash
mix dialyzer
```

Expected: no warnings

- [ ] **Step 3: Fix any issues found, commit if needed**

---

### Task 10: Mark TODO as done

- [ ] **Step 1: Run mix todo --done**

```bash
mix todo --done
```

This marks the `sev status` TODO item as complete in the README and commits the change.
