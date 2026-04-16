# Activity Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent plain-text activity log that tracks daemon sessions (start/stop with duration) and overtime protocol usage, with a configurable log file location.

**Architecture:** New `Severance.ActivityLog` plain module handles all file I/O (append-only writes). Config gains a `log_file` key resolved through existing layering. Countdown GenServer calls ActivityLog at key lifecycle points. New `sev log` CLI command prints the log.

**Tech Stack:** Elixir, File I/O, ExUnit with temp directories

---

### Task 1: `Severance.ActivityLog` — format_entry and default_log_file

**Files:**
- Create: `lib/severance/activity_log.ex`
- Create: `test/severance/activity_log_test.exs`

- [ ] **Step 1: Write failing tests for `format_entry/2` and `default_log_file/0`**

```elixir
defmodule Severance.ActivityLogTest do
  use ExUnit.Case, async: true

  alias Severance.ActivityLog

  describe "default_log_file/0" do
    test "returns path under ~/.local/state/severance" do
      path = ActivityLog.default_log_file()
      assert path =~ ".local/state/severance/activity.log"
      assert String.starts_with?(path, System.user_home!())
    end
  end

  describe "format_entry/2" do
    test "formats a started event" do
      timestamp = ~N[2026-04-15 10:00:00]
      assert ActivityLog.format_entry(:started, timestamp: timestamp) ==
               "2026-04-15T10:00:00 started"
    end

    test "formats an overtime event" do
      timestamp = ~N[2026-04-15 16:45:00]
      assert ActivityLog.format_entry(:overtime, timestamp: timestamp) ==
               "2026-04-15T16:45:00 overtime"
    end

    test "formats a stopped event with duration" do
      timestamp = ~N[2026-04-15 18:30:00]
      assert ActivityLog.format_entry(:stopped, timestamp: timestamp, duration_minutes: 510) ==
               "2026-04-15T18:30:00 stopped duration_minutes=510"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/severance/activity_log_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Implement `ActivityLog` with `format_entry/2` and `default_log_file/0`**

```elixir
defmodule Severance.ActivityLog do
  @moduledoc """
  Writes timestamped activity entries to a plain-text log file.

  Tracks daemon sessions (start/stop with duration) and overtime
  protocol activations. Each entry is one line, greppable:

      2026-04-15T10:00:00 started
      2026-04-15T16:45:00 overtime
      2026-04-15T18:30:00 stopped duration_minutes=510
  """

  @default_log_file Path.join([System.user_home!(), ".local", "state", "severance", "activity.log"])

  @doc """
  Returns the default log file path (`~/.local/state/severance/activity.log`).
  """
  @spec default_log_file() :: String.t()
  def default_log_file, do: @default_log_file

  @doc """
  Formats a log entry as a single line string.

  ## Options

  - `:timestamp` — `NaiveDateTime.t()` for the entry (required)
  - `:duration_minutes` — integer minutes, included for `:stopped` events
  """
  @spec format_entry(:started | :overtime | :stopped, keyword()) :: String.t()
  def format_entry(event, opts) do
    timestamp = Keyword.fetch!(opts, :timestamp)
    ts_str = NaiveDateTime.to_iso8601(timestamp, :basic)
    ts_str = format_timestamp(timestamp)
    base = "#{ts_str} #{event}"

    case Keyword.get(opts, :duration_minutes) do
      nil -> base
      minutes -> "#{base} duration_minutes=#{minutes}"
    end
  end

  defp format_timestamp(ndt) do
    Calendar.strftime(ndt, "%Y-%m-%dT%H:%M:%S")
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/severance/activity_log_test.exs`
Expected: 3 tests, 0 failures

- [ ] **Step 5: Run format and credo**

Run: `mix format lib/severance/activity_log.ex test/severance/activity_log_test.exs && mix credo --strict`

- [ ] **Step 6: Commit**

```bash
git add lib/severance/activity_log.ex test/severance/activity_log_test.exs
git commit -m "Add ActivityLog module with format_entry and default_log_file"
```

---

### Task 2: `ActivityLog` — file I/O (log_started, log_overtime, log_stopped)

**Files:**
- Modify: `lib/severance/activity_log.ex`
- Modify: `test/severance/activity_log_test.exs`

- [ ] **Step 1: Write failing tests for `log_started/1`, `log_overtime/1`, `log_stopped/1`**

Append to the test file:

```elixir
  describe "log_started/1" do
    setup :tmp_log_file

    test "creates parent directory and appends started entry", %{log_file: log_file} do
      frozen = ~N[2026-04-15 10:00:00]
      Application.put_env(:severance, :now_fn, fn -> frozen end)
      on_exit(fn -> Application.delete_env(:severance, :now_fn) end)

      assert :ok = ActivityLog.log_started(log_file)

      contents = File.read!(log_file)
      assert contents =~ "2026-04-15T10:00:00 started"
    end

    test "stores start time in Application env", %{log_file: log_file} do
      frozen = ~N[2026-04-15 10:00:00]
      Application.put_env(:severance, :now_fn, fn -> frozen end)

      on_exit(fn ->
        Application.delete_env(:severance, :now_fn)
        Application.delete_env(:severance, :activity_log_started_at)
      end)

      ActivityLog.log_started(log_file)

      assert Application.get_env(:severance, :activity_log_started_at) == frozen
    end
  end

  describe "log_overtime/1" do
    setup :tmp_log_file

    test "appends overtime entry", %{log_file: log_file} do
      frozen = ~N[2026-04-15 16:45:00]
      Application.put_env(:severance, :now_fn, fn -> frozen end)
      on_exit(fn -> Application.delete_env(:severance, :now_fn) end)

      assert :ok = ActivityLog.log_overtime(log_file)

      contents = File.read!(log_file)
      assert contents =~ "2026-04-15T16:45:00 overtime"
    end
  end

  describe "log_stopped/1" do
    setup :tmp_log_file

    test "appends stopped entry with duration", %{log_file: log_file} do
      start = ~N[2026-04-15 10:00:00]
      stop = ~N[2026-04-15 18:30:00]
      Application.put_env(:severance, :activity_log_started_at, start)
      Application.put_env(:severance, :now_fn, fn -> stop end)

      on_exit(fn ->
        Application.delete_env(:severance, :now_fn)
        Application.delete_env(:severance, :activity_log_started_at)
      end)

      assert :ok = ActivityLog.log_stopped(log_file)

      contents = File.read!(log_file)
      assert contents =~ "2026-04-15T18:30:00 stopped duration_minutes=510"
    end

    test "handles missing start time gracefully", %{log_file: log_file} do
      frozen = ~N[2026-04-15 18:30:00]
      Application.delete_env(:severance, :activity_log_started_at)
      Application.put_env(:severance, :now_fn, fn -> frozen end)
      on_exit(fn -> Application.delete_env(:severance, :now_fn) end)

      assert :ok = ActivityLog.log_stopped(log_file)

      contents = File.read!(log_file)
      assert contents =~ "2026-04-15T18:30:00 stopped"
      refute contents =~ "duration_minutes"
    end
  end

  defp tmp_log_file(_context) do
    dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")
    log_file = Path.join(dir, "activity.log")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{log_file: log_file, log_dir: dir}
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/severance/activity_log_test.exs`
Expected: FAIL — functions not defined

- [ ] **Step 3: Implement the three log functions**

Add to `lib/severance/activity_log.ex`:

```elixir
  @doc """
  Logs a daemon started event. Stores the start time in Application env
  for duration calculation when the daemon stops.
  """
  @spec log_started(String.t()) :: :ok
  def log_started(log_file) do
    now = local_now()
    Application.put_env(:severance, :activity_log_started_at, now)
    append(log_file, format_entry(:started, timestamp: now))
  end

  @doc """
  Logs an overtime protocol activation event.
  """
  @spec log_overtime(String.t()) :: :ok
  def log_overtime(log_file) do
    append(log_file, format_entry(:overtime, timestamp: local_now()))
  end

  @doc """
  Logs a daemon stopped event with session duration in minutes.

  Duration is calculated from the start time stored by `log_started/1`.
  If no start time is available (abnormal state), logs without duration.
  """
  @spec log_stopped(String.t()) :: :ok
  def log_stopped(log_file) do
    now = local_now()

    opts =
      case Application.get_env(:severance, :activity_log_started_at) do
        nil ->
          [timestamp: now]

        started_at ->
          duration = NaiveDateTime.diff(now, started_at, :minute)
          [timestamp: now, duration_minutes: duration]
      end

    append(log_file, format_entry(:stopped, opts))
  end

  defp append(log_file, line) do
    log_file |> Path.dirname() |> File.mkdir_p!()
    File.write!(log_file, line <> "\n", [:append])
    :ok
  end

  defp local_now do
    case Application.get_env(:severance, :now_fn) do
      nil -> NaiveDateTime.local_now()
      fun -> fun.()
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/severance/activity_log_test.exs`
Expected: all pass

- [ ] **Step 5: Run format and credo**

Run: `mix format lib/severance/activity_log.ex test/severance/activity_log_test.exs && mix credo --strict`

- [ ] **Step 6: Commit**

```bash
git add lib/severance/activity_log.ex test/severance/activity_log_test.exs
git commit -m "Add file I/O functions to ActivityLog"
```

---

### Task 3: Config — add `log_file` key

**Files:**
- Modify: `lib/severance/config.ex:11-14` (add to `@default_config`)
- Modify: `lib/severance/config.ex:62-68` (`generate_contents/1`)
- Modify: `test/severance/config_test.exs`

- [ ] **Step 1: Write failing tests for `log_file` in config**

Add to `test/severance/config_test.exs`:

In the `defaults/0` describe block, update the existing test:

```elixir
    test "returns map with shutdown_time and overtime_notifications" do
      defaults = Config.defaults()

      assert %{
               shutdown_time: "17:00",
               overtime_notifications: true,
               log_file: log_file
             } = defaults

      assert log_file =~ ".local/state/severance/activity.log"
      refute Map.has_key?(defaults, :timezone)
    end
```

In the `generate_contents/1` describe block, update the existing round-trip test:

```elixir
    test "generates valid Elixir term that round-trips back to the input map" do
      config = %{
        shutdown_time: "16:30",
        overtime_notifications: false,
        log_file: "~/.local/state/severance/activity.log"
      }

      contents = Config.generate_contents(config)
      {result, _bindings} = Code.eval_string(contents)

      assert result == config
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/severance/config_test.exs`
Expected: FAIL — `log_file` key missing from defaults, `generate_contents` doesn't match

- [ ] **Step 3: Update `Config` module**

In `lib/severance/config.ex`, update `@default_config`:

```elixir
  @default_config %{
    shutdown_time: "17:00",
    overtime_notifications: true,
    log_file: Path.join([System.user_home!(), ".local", "state", "severance", "activity.log"])
  }
```

Update `generate_contents/1`:

```elixir
  def generate_contents(config) do
    """
    %{
      shutdown_time: #{inspect(config.shutdown_time)},
      overtime_notifications: #{inspect(config.overtime_notifications)},
      log_file: #{inspect(config.log_file)}
    }
    """
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/severance/config_test.exs`
Expected: all pass

- [ ] **Step 5: Run format and credo**

Run: `mix format lib/severance/config.ex test/severance/config_test.exs && mix credo --strict`

- [ ] **Step 6: Commit**

```bash
git add lib/severance/config.ex test/severance/config_test.exs
git commit -m "Add log_file key to config defaults"
```

---

### Task 4: Application — resolve log_file, call log_started

**Files:**
- Modify: `lib/severance/application.ex:175-187` (`start_daemon/1`)
- Modify: `lib/severance/application.ex:117-160` (`resolve_config/2`)
- Modify: `test/severance/application_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/severance/application_test.exs` inside the `resolve_config/1` describe:

```elixir
    test "resolves log_file from config file" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "17:00", overtime_notifications: true, log_file: "/custom/path/sev.log"})

      File.write!(Path.join(dir, "config.exs"), config_content)

      resolved = Application.resolve_config([], config_dir: dir)

      assert resolved.log_file == "/custom/path/sev.log"
    end

    test "uses default log_file when config file has no log_file key" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "17:00", overtime_notifications: true})

      File.write!(Path.join(dir, "config.exs"), config_content)

      resolved = Application.resolve_config([], config_dir: dir)

      assert resolved.log_file =~ ".local/state/severance/activity.log"
    end

    test "stores log_file in Application env" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "17:00", overtime_notifications: true, log_file: "/tmp/test.log"})

      File.write!(Path.join(dir, "config.exs"), config_content)

      Application.resolve_config([], config_dir: dir)

      assert Elixir.Application.get_env(:severance, :log_file) == "/tmp/test.log"
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/severance/application_test.exs`
Expected: FAIL — `log_file` key missing from resolved config

- [ ] **Step 3: Update `resolve_config/2` to include `log_file`**

In `lib/severance/application.ex`, update `resolve_config/2`:

After the existing config file reading block, add log_file resolution. The function should:
1. Read `log_file` from config file (or use default from `Severance.ActivityLog.default_log_file()`)
2. Expand `~` via `Path.expand/1`
3. Store in Application env
4. Include in return map

Update the `@spec` to include `log_file: String.t()` in the return type.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/severance/application_test.exs`
Expected: all pass

- [ ] **Step 5: Add `log_started` call to `start_daemon/1`**

In `lib/severance/application.ex`, after `Supervisor.start_link/2` in `start_daemon/1`, add:

```elixir
    result = Supervisor.start_link(children, sup_opts)

    if start_children do
      log_file = Application.get_env(:severance, :log_file, ActivityLog.default_log_file())
      ActivityLog.log_started(log_file)
    end

    result
```

Add `alias Severance.ActivityLog` to the module.

- [ ] **Step 6: Run format and credo**

Run: `mix format lib/severance/application.ex test/severance/application_test.exs && mix credo --strict`

- [ ] **Step 7: Run full test suite**

Run: `mix test`
Expected: all pass

- [ ] **Step 8: Commit**

```bash
git add lib/severance/application.ex test/severance/application_test.exs
git commit -m "Resolve log_file config and log started on daemon boot"
```

---

### Task 5: Countdown — log overtime and stopped

**Files:**
- Modify: `lib/severance/countdown.ex:130-132` (`handle_call(:overtime, ...)`)
- Modify: `lib/severance/countdown.ex` (add `terminate/2`)
- Modify: `test/severance/countdown_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/severance/countdown_test.exs`:

```elixir
  describe "activity log integration" do
    setup do
      dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")
      log_file = Path.join(dir, "activity.log")
      Application.put_env(:severance, :log_file, log_file)

      on_exit(fn ->
        Application.delete_env(:severance, :log_file)
        Application.delete_env(:severance, :activity_log_started_at)
        File.rm_rf!(dir)
      end)

      %{log_file: log_file}
    end

    test "overtime/0 logs an overtime event", %{log_file: log_file} do
      start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})
      Countdown.overtime()

      assert File.exists?(log_file)
      contents = File.read!(log_file)
      assert contents =~ "overtime"
    end

    test "terminate logs a stopped event", %{log_file: log_file} do
      Application.put_env(:severance, :activity_log_started_at, @frozen_now)
      pid = start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})

      GenServer.stop(pid)
      # Give terminate a moment
      Process.sleep(50)

      assert File.exists?(log_file)
      contents = File.read!(log_file)
      assert contents =~ "stopped"
      assert contents =~ "duration_minutes="
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/severance/countdown_test.exs`
Expected: FAIL — no overtime log entry, no terminate callback

- [ ] **Step 3: Implement overtime logging in `handle_call(:overtime, ...)`**

In `lib/severance/countdown.ex`, update the `:overtime` handler:

```elixir
  @impl true
  def handle_call(:overtime, _from, state) do
    log_file = Application.get_env(:severance, :log_file, ActivityLog.default_log_file())
    ActivityLog.log_overtime(log_file)
    {:reply, :ok, %{state | mode: :overtime}}
  end
```

Add `alias Severance.ActivityLog` to the module aliases.

- [ ] **Step 4: Implement `terminate/2`**

Add to `lib/severance/countdown.ex`:

```elixir
  @impl true
  def terminate(_reason, _state) do
    log_file = Application.get_env(:severance, :log_file, ActivityLog.default_log_file())
    ActivityLog.log_stopped(log_file)
    :ok
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/severance/countdown_test.exs`
Expected: all pass

- [ ] **Step 6: Run format and credo**

Run: `mix format lib/severance/countdown.ex test/severance/countdown_test.exs && mix credo --strict`

- [ ] **Step 7: Commit**

```bash
git add lib/severance/countdown.ex test/severance/countdown_test.exs
git commit -m "Log overtime and stopped events from Countdown"
```

---

### Task 6: CLI — `sev log` command

**Files:**
- Modify: `lib/severance/cli.ex:60` (add `parse_args` clause)
- Modify: `lib/severance/cli.ex:1-19` (update moduledoc)
- Modify: `lib/severance/application.ex` (add `dispatch(:log)`)
- Modify: `test/severance/cli_test.exs`

- [ ] **Step 1: Write failing test for `parse_args`**

Add to `test/severance/cli_test.exs` in the `parse_args/1` describe:

```elixir
    test "log arg returns :log" do
      assert CLI.parse_args(["log"]) == :log
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/severance/cli_test.exs --only line:XX`
Expected: FAIL — `parse_args(["log"])` returns `:start`

- [ ] **Step 3: Add `parse_args` clause**

In `lib/severance/cli.ex`, add before the existing `parse_args(["start"])` clause:

```elixir
  def parse_args(["log" | _rest]), do: :log
```

Update the `@type parse_args_result` to include `:log`.

Update the `@moduledoc` to include:

```
    sev log                    # Print the activity log
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/severance/cli_test.exs`
Expected: all pass

- [ ] **Step 5: Write failing test for `dispatch(:log)` / `run_log`**

Add a new describe block to `test/severance/cli_test.exs`:

```elixir
  describe "run_log/1" do
    test "prints log file contents" do
      dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")
      log_file = Path.join(dir, "activity.log")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)
      File.write!(log_file, "2026-04-15T10:00:00 started\n2026-04-15T16:45:00 overtime\n")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.run_log(log_file)
        end)

      assert output =~ "2026-04-15T10:00:00 started"
      assert output =~ "2026-04-15T16:45:00 overtime"
    end

    test "prints message when log file does not exist" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.run_log("/nonexistent/path/activity.log")
        end)

      assert output =~ "No activity log found"
    end
  end
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `mix test test/severance/cli_test.exs`
Expected: FAIL — `run_log/1` undefined

- [ ] **Step 7: Implement `run_log/1` in CLI**

Add to `lib/severance/cli.ex`:

```elixir
  @doc """
  Prints the activity log to stdout.

  If the log file doesn't exist, prints a message indicating no log was found.
  """
  @spec run_log(String.t()) :: :ok
  def run_log(log_file) do
    if File.exists?(log_file) do
      log_file |> File.read!() |> IO.write()
    else
      IO.puts("No activity log found at #{log_file}")
    end

    :ok
  end
```

- [ ] **Step 8: Add `dispatch(:log)` to Application**

In `lib/severance/application.ex`, add a dispatch clause:

```elixir
  defp dispatch(:log) do
    config = resolve_config([], suppress_warning: true)
    log_file = config.log_file
    CLI.run_log(log_file)
    System.halt(0)
  end
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `mix test test/severance/cli_test.exs test/severance/application_test.exs`
Expected: all pass

- [ ] **Step 10: Run format and credo**

Run: `mix format lib/severance/cli.ex lib/severance/application.ex test/severance/cli_test.exs && mix credo --strict`

- [ ] **Step 11: Commit**

```bash
git add lib/severance/cli.ex lib/severance/application.ex test/severance/cli_test.exs
git commit -m "Add sev log command"
```

---

### Task 7: Documentation — README, CHANGELOG, config example

**Files:**
- Modify: `README.md:110-116` (usage table)
- Modify: `README.md:134-141` (config example)
- Modify: `CHANGELOG.md:9` (unreleased section)

- [ ] **Step 1: Update README usage section**

Add `sev log` to the usage block:

```bash
sev            # start the daemon
sev status     # show daemon status and version info
sev otp        # activate overtime protocol
sev log        # print the activity log
sev update     # update to latest release
sev version    # print current version
```

- [ ] **Step 2: Update README config example**

Update the config file example to include `log_file`:

```elixir
%{
  shutdown_time: "17:00",
  overtime_notifications: true,
  log_file: "~/.local/state/severance/activity.log"
}
```

Add a line after the `overtime_notifications` explanation:

> Set `log_file` to a custom path to change where the activity log is
> written. Defaults to `~/.local/state/severance/activity.log`.

- [ ] **Step 3: Update CHANGELOG**

Add under `## [Unreleased]` → `### Added`:

```markdown
- Activity log tracking daemon sessions and overtime protocol usage (`sev log` to view)
- `log_file` configuration option for custom activity log location
```

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "Document activity log in README and CHANGELOG"
```

---

### Task 8: Full quality check and dialyzer

- [ ] **Step 1: Run the full quality suite**

Run: `mix quality`
Expected: all checks pass

- [ ] **Step 2: Fix any issues found**

Address any format, credo, dialyzer, or test failures.

- [ ] **Step 3: Commit fixes if any**

```bash
git add -A
git commit -m "Fix quality issues"
```
