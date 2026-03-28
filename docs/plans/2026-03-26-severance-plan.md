# Severance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an Elixir OTP daemon that enforces a hard daily computer shutdown with escalating warnings, stale tmux pane detection, and an RPC-based escape hatch (Overtime Protocol).

**Architecture:** GenServer-based countdown timer running as a named BEAM node. The CLI binary either starts the daemon or connects to a running instance to toggle overtime mode. System commands (notifications, tmux, shutdown) are injected via a behaviour so tests never touch real system state.

**Tech Stack:** Elixir 1.19 / OTP 28, Mix release, launchd, macOS `osascript`, tmux

---

## File Map

| File | Responsibility |
|---|---|
| `mix.exs` | Project config, release config |
| `config/config.exs` | Default shutdown time |
| `config/runtime.exs` | CLI flag override for shutdown time |
| `config/test.exs` | Test-specific config (mock system adapter) |
| `rel/env.sh.eex` | Sets node name and cookie for release |
| `lib/severance.ex` | Top-level module, delegates to CLI |
| `lib/severance/application.ex` | OTP Application, starts supervisor |
| `lib/severance/cli.ex` | Arg parsing, daemon start vs OTP RPC |
| `lib/severance/countdown.ex` | GenServer — state machine, timer logic |
| `lib/severance/notifier.ex` | macOS notification functions |
| `lib/severance/tmux.ex` | Tmux status bar and stale pane detection |
| `lib/severance/system.ex` | Behaviour for system commands (shutdown, osascript, tmux) |
| `lib/severance/system/real.ex` | Real implementation — calls actual system commands |
| `lib/severance/system/test.ex` | Test implementation — records calls, no side effects |
| `test/test_helper.exs` | Test setup |
| `test/severance/countdown_test.exs` | Countdown state machine tests |
| `test/severance/tmux_test.exs` | Stale pane parsing tests |
| `test/severance/notifier_test.exs` | Notification delegation tests |
| `test/severance/cli_test.exs` | Arg parsing tests |

---

## Task 1: Project Scaffold

**Files:**
- Create: `mix.exs`
- Create: `config/config.exs`
- Create: `config/test.exs`
- Create: `lib/severance.ex`
- Create: `lib/severance/application.ex`
- Create: `test/test_helper.exs`
- Create: `.gitignore`
- Create: `.formatter.exs`

- [ ] **Step 1: Create the Mix project**

```bash
cd ~/severance
mix new severance --app severance --sup
```

This generates the scaffold. We'll overwrite most of the generated files in subsequent steps.

- [ ] **Step 2: Replace `mix.exs` with release config**

```elixir
defmodule Severance.MixProject do
  use Mix.Project

  def project do
    [
      app: :severance,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Severance.Application, []}
    ]
  end

  defp deps do
    [
      {:tz, "~> 0.28"}
    ]
  end

  defp releases do
    [
      severance: [
        steps: [:assemble],
        include_executables_for: [:unix]
      ]
    ]
  end
end
```

- [ ] **Step 3: Write `config/config.exs`**

```elixir
import Config

config :severance,
  shutdown_time: ~T[16:30:00],
  system_adapter: Severance.System.Real,
  timezone: "America/Los_Angeles"

import_config "#{config_env()}.exs"
```

- [ ] **Step 4: Write `config/test.exs`**

```elixir
import Config

config :severance,
  system_adapter: Severance.System.Test
```

- [ ] **Step 5: Write `config/runtime.exs`**

```elixir
import Config

if shutdown_time = System.get_env("SEVERANCE_SHUTDOWN_TIME") do
  config :severance, shutdown_time: Time.from_iso8601!(shutdown_time)
end
```

- [ ] **Step 6: Write the top-level module `lib/severance.ex`**

```elixir
defmodule Severance do
  @moduledoc """
  Enforces a hard daily computer shutdown with escalating warnings.

  Run `severance` to start the daemon.
  Run `severance otp` to activate the Overtime Protocol on a running instance.
  """
end
```

- [ ] **Step 7: Write `lib/severance/application.ex`**

```elixir
defmodule Severance.Application do
  @moduledoc """
  OTP Application entry point. Starts the supervision tree with
  the Countdown GenServer.
  """

  use Application

  @impl true
  def start(_type, _args) do
    shutdown_time = Application.get_env(:severance, :shutdown_time, ~T[16:30:00])

    children = [
      {Severance.Countdown, shutdown_time: shutdown_time}
    ]

    opts = [strategy: :one_for_one, name: Severance.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 8: Write `.formatter.exs`**

```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

- [ ] **Step 9: Update `.gitignore`**

```
/_build/
/deps/
/doc/
/.fetch
erl_crash.dump
*.ez
severance-*.tar
/tmp/
```

- [ ] **Step 10: Fetch deps and verify compilation**

```bash
cd ~/severance
mix deps.get
mix compile
```

Expected: compiles with warnings about missing `Severance.Countdown`, `Severance.System.Real`, and `Severance.System.Test` modules. That's fine — we build those next.

- [ ] **Step 11: Commit**

```bash
cd ~/severance
git add mix.exs mix.lock config/ lib/ test/ .gitignore .formatter.exs
git commit -m "Scaffold Mix project with release config"
```

---

## Task 2: System Behaviour and Adapters

**Files:**
- Create: `lib/severance/system.ex`
- Create: `lib/severance/system/real.ex`
- Create: `lib/severance/system/test.ex`

This is the injection layer that keeps real `osascript`, `tmux`, and `shutdown` calls out of tests.

- [ ] **Step 1: Write `lib/severance/system.ex`**

```elixir
defmodule Severance.System do
  @moduledoc """
  Behaviour defining system interaction callbacks.

  Implementations handle macOS notifications, tmux commands, and
  machine shutdown. The active adapter is configured via
  `:severance, :system_adapter`.
  """

  @callback notify(title :: String.t(), message :: String.t(), sound :: String.t()) :: :ok
  @callback shutdown_machine() :: :ok
  @callback tmux_cmd(args :: [String.t()]) :: {String.t(), non_neg_integer()}

  @doc """
  Returns the configured system adapter module.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:severance, :system_adapter, Severance.System.Real)
  end
end
```

- [ ] **Step 2: Write `lib/severance/system/real.ex`**

```elixir
defmodule Severance.System.Real do
  @moduledoc """
  Real system adapter. Calls osascript for notifications and shutdown,
  and tmux for status bar manipulation.
  """

  @behaviour Severance.System

  @impl true
  def notify(title, message, sound) do
    script =
      ~s(display notification "#{message}" with title "#{title}" sound name "#{sound}")

    System.cmd("osascript", ["-e", script])
    :ok
  end

  @impl true
  def shutdown_machine do
    System.cmd("osascript", ["-e", ~s(tell app "System Events" to shut down)])
    :ok
  end

  @impl true
  def tmux_cmd(args) do
    System.cmd("tmux", args, stderr_to_stdout: true)
  end
end
```

- [ ] **Step 3: Write `lib/severance/system/test.ex`**

```elixir
defmodule Severance.System.Test do
  @moduledoc """
  Test adapter that records system calls in the calling process's
  message inbox instead of executing them.
  """

  @behaviour Severance.System

  @impl true
  def notify(title, message, sound) do
    send(self(), {:notify, title, message, sound})
    :ok
  end

  @impl true
  def shutdown_machine do
    send(self(), :shutdown_machine)
    :ok
  end

  @impl true
  def tmux_cmd(args) do
    send(self(), {:tmux_cmd, args})
    {"", 0}
  end
end
```

- [ ] **Step 4: Verify compilation**

```bash
cd ~/severance
mix compile
```

Expected: clean compilation, no warnings.

- [ ] **Step 5: Commit**

```bash
cd ~/severance
git add lib/severance/system.ex lib/severance/system/real.ex lib/severance/system/test.ex
git commit -m "Add system behaviour and real/test adapters"
```

---

## Task 3: Tmux Module

**Files:**
- Create: `lib/severance/tmux.ex`
- Create: `test/severance/tmux_test.exs`

- [ ] **Step 1: Write the failing tests for stale pane parsing in `test/severance/tmux_test.exs`**

```elixir
defmodule Severance.TmuxTest do
  use ExUnit.Case, async: true

  alias Severance.Tmux

  describe "parse_stale_panes/2" do
    test "returns panes with activity older than threshold" do
      now = System.os_time(:second)
      old = now - 20 * 60
      recent = now - 5 * 60

      raw_output =
        "dev:editor.0 /Users/kyle/project1 #{old}\n" <>
          "dev:server.1 /Users/kyle/project1 #{recent}\n" <>
          "notes:main.0 /Users/kyle/notes #{old}\n"

      stale = Tmux.parse_stale_panes(raw_output, now - 15 * 60)

      assert length(stale) == 2
      assert %{pane: "dev:editor.0", path: "/Users/kyle/project1"} in stale
      assert %{pane: "notes:main.0", path: "/Users/kyle/notes"} in stale
    end

    test "returns empty list when all panes are active" do
      now = System.os_time(:second)
      recent = now - 5 * 60

      raw_output = "dev:editor.0 /Users/kyle/project1 #{recent}\n"

      assert Tmux.parse_stale_panes(raw_output, now - 15 * 60) == []
    end

    test "handles empty tmux output" do
      now = System.os_time(:second)
      assert Tmux.parse_stale_panes("", now - 15 * 60) == []
    end

    test "skips malformed lines" do
      now = System.os_time(:second)
      old = now - 20 * 60

      raw_output = "bad line\ndev:editor.0 /Users/kyle/project1 #{old}\n"

      stale = Tmux.parse_stale_panes(raw_output, now - 15 * 60)
      assert length(stale) == 1
      assert %{pane: "dev:editor.0", path: "/Users/kyle/project1"} in stale
    end
  end

  describe "countdown_status/3" do
    test "returns yellow prefix for gentle phase" do
      result = Tmux.countdown_status(25, :gentle, "original")
      assert result == "#[fg=colour226,bold] STOP:25m #[default]original"
    end

    test "returns red blinking prefix for aggressive phase" do
      result = Tmux.countdown_status(10, :aggressive, "original")
      assert result == "#[fg=colour196,bold,blink] STOP:10m #[default]original"
    end

    test "returns red blinking prefix for final phase" do
      result = Tmux.countdown_status(3, :final, "original")
      assert result == "#[fg=colour196,bold,blink] STOP:3m #[default]original"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/severance
mix test test/severance/tmux_test.exs
```

Expected: compilation errors — `Severance.Tmux` module doesn't exist.

- [ ] **Step 3: Write `lib/severance/tmux.ex`**

```elixir
defmodule Severance.Tmux do
  @moduledoc """
  Tmux interaction helpers for status bar manipulation and
  stale pane detection.
  """

  @doc """
  Reads the current tmux global `status-right` value.
  """
  @spec capture_status_right() :: String.t()
  def capture_status_right do
    {output, 0} = system().tmux_cmd(["show-option", "-gv", "status-right"])
    String.trim(output)
  end

  @doc """
  Sets tmux global `status-right` to the given value.
  """
  @spec set_status_right(String.t()) :: :ok
  def set_status_right(value) do
    system().tmux_cmd(["set-option", "-g", "status-right", value])
    :ok
  end

  @doc """
  Builds the countdown status string for a given phase.
  Prepends a colored prefix to the original status.
  """
  @spec countdown_status(non_neg_integer(), :gentle | :aggressive | :final, String.t()) ::
          String.t()
  def countdown_status(minutes_left, phase, original_status) do
    {color, extra} =
      case phase do
        :gentle -> {"colour226", ""}
        :aggressive -> {"colour196", ",blink"}
        :final -> {"colour196", ",blink"}
      end

    "#[fg=#{color},bold#{extra}] STOP:#{minutes_left}m #[default]#{original_status}"
  end

  @doc """
  Queries tmux for all panes and returns those with no activity
  in the last `stale_threshold_minutes` minutes.
  """
  @spec stale_panes(non_neg_integer()) :: [%{pane: String.t(), path: String.t()}]
  def stale_panes(stale_threshold_minutes) do
    {output, _} =
      system().tmux_cmd([
        "list-panes",
        "-a",
        "-F",
        "\#{session_name}:\#{window_name}.\#{pane_index} \#{pane_current_path} \#{pane_activity}"
      ])

    cutoff = System.os_time(:second) - stale_threshold_minutes * 60
    parse_stale_panes(output, cutoff)
  end

  @doc """
  Parses raw tmux pane output and returns panes with last activity
  before the given cutoff (unix timestamp in seconds).
  """
  @spec parse_stale_panes(String.t(), integer()) :: [%{pane: String.t(), path: String.t()}]
  def parse_stale_panes(raw_output, cutoff) do
    raw_output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, " ") do
        [pane, path, activity_str] ->
          case Integer.parse(activity_str) do
            {activity, ""} when activity < cutoff ->
              [%{pane: pane, path: path}]

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  defp system, do: Severance.System.adapter()
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/severance
mix test test/severance/tmux_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Format and lint**

```bash
cd ~/severance
mix format lib/severance/tmux.ex test/severance/tmux_test.exs
mix credo --strict
```

- [ ] **Step 6: Commit**

```bash
cd ~/severance
git add lib/severance/tmux.ex test/severance/tmux_test.exs
git commit -m "Add tmux module with stale pane detection"
```

---

## Task 4: Notifier Module

**Files:**
- Create: `lib/severance/notifier.ex`
- Create: `test/severance/notifier_test.exs`

- [ ] **Step 1: Write the failing tests in `test/severance/notifier_test.exs`**

```elixir
defmodule Severance.NotifierTest do
  use ExUnit.Case, async: true

  alias Severance.Notifier

  describe "phase_sound/1" do
    test "returns Tink for gentle phase" do
      assert Notifier.phase_sound(:gentle) == "Tink"
    end

    test "returns Funk for aggressive phase" do
      assert Notifier.phase_sound(:aggressive) == "Funk"
    end

    test "returns Basso for final phase" do
      assert Notifier.phase_sound(:final) == "Basso"
    end

    test "returns Basso for overtime phase" do
      assert Notifier.phase_sound(:overtime) == "Basso"
    end
  end

  describe "countdown_message/2" do
    test "severance mode warns about shutdown" do
      assert Notifier.countdown_message(15, :severance) ==
               {"Shutdown in 15m", "Your computer WILL shut down. Push your work."}
    end

    test "overtime mode warns without shutdown threat" do
      assert Notifier.countdown_message(15, :overtime) ==
               {"Shutdown in 15m", "Start wrapping up and push your work."}
    end

    test "uses urgent language at 5 minutes" do
      {title, _body} = Notifier.countdown_message(5, :severance)
      assert title == "SHUTDOWN IN 5m"
    end

    test "uses urgent language at 1 minute" do
      {title, body} = Notifier.countdown_message(1, :severance)
      assert title == "FINAL WARNING"
      assert body =~ "1 minute"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/severance
mix test test/severance/notifier_test.exs
```

Expected: compilation error — `Severance.Notifier` doesn't exist.

- [ ] **Step 3: Write `lib/severance/notifier.ex`**

```elixir
defmodule Severance.Notifier do
  @moduledoc """
  Builds and sends macOS notifications with escalating urgency
  based on countdown phase.
  """

  @doc """
  Returns the notification sound for a given phase.
  """
  @spec phase_sound(:gentle | :aggressive | :final | :overtime) :: String.t()
  def phase_sound(:gentle), do: "Tink"
  def phase_sound(:aggressive), do: "Funk"
  def phase_sound(:final), do: "Basso"
  def phase_sound(:overtime), do: "Basso"

  @doc """
  Returns {title, body} for a countdown notification based on
  minutes remaining and current mode.
  """
  @spec countdown_message(non_neg_integer(), :severance | :overtime) ::
          {String.t(), String.t()}
  def countdown_message(1, :severance) do
    {"FINAL WARNING", "Your computer shuts down in 1 minute. Save everything."}
  end

  def countdown_message(1, :overtime) do
    {"FINAL WARNING", "1 minute left. Push your work."}
  end

  def countdown_message(minutes, mode) when minutes <= 5 do
    body =
      case mode do
        :severance -> "Your computer WILL shut down. Save everything NOW."
        :overtime -> "Push your work NOW."
      end

    {"SHUTDOWN IN #{minutes}m", body}
  end

  def countdown_message(minutes, mode) do
    body =
      case mode do
        :severance -> "Your computer WILL shut down. Push your work."
        :overtime -> "Start wrapping up and push your work."
      end

    {"Shutdown in #{minutes}m", body}
  end

  @doc """
  Sends a countdown notification for the given minutes and mode.
  """
  @spec send_countdown(non_neg_integer(), :severance | :overtime, :gentle | :aggressive | :final) ::
          :ok
  def send_countdown(minutes, mode, phase) do
    {title, body} = countdown_message(minutes, mode)
    sound = phase_sound(phase)
    system().notify(title, body, sound)
  end

  @doc """
  Sends a notification about a stale tmux pane.
  """
  @spec send_stale_pane(%{pane: String.t(), path: String.t()}) :: :ok
  def send_stale_pane(%{pane: pane, path: path}) do
    system().notify(
      "Stale pane: #{pane}",
      "No activity in 15m. Leave a breadcrumb.\n#{path}",
      "Tink"
    )
  end

  @doc """
  Sends the overtime burst notification (used every 5 seconds).
  """
  @spec send_overtime_burst() :: :ok
  def send_overtime_burst do
    system().notify(
      "GO HOME",
      "You said you'd stop working. Go be a person.",
      "Basso"
    )
  end

  defp system, do: Severance.System.adapter()
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/severance
mix test test/severance/notifier_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Format and lint**

```bash
cd ~/severance
mix format lib/severance/notifier.ex test/severance/notifier_test.exs
mix credo --strict
```

- [ ] **Step 6: Commit**

```bash
cd ~/severance
git add lib/severance/notifier.ex test/severance/notifier_test.exs
git commit -m "Add notifier module with escalating messages"
```

---

## Task 5: Countdown GenServer

**Files:**
- Create: `lib/severance/countdown.ex`
- Create: `test/severance/countdown_test.exs`

This is the core state machine. The GenServer sleeps until T-30, then ticks through phases.

- [ ] **Step 1: Write the failing tests in `test/severance/countdown_test.exs`**

```elixir
defmodule Severance.CountdownTest do
  use ExUnit.Case, async: false

  alias Severance.Countdown

  describe "overtime/0" do
    test "switches mode from severance to overtime" do
      start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})

      assert :ok = Countdown.overtime()
      assert Countdown.mode() == :overtime
    end
  end

  describe "mode/0" do
    test "defaults to severance mode" do
      start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})

      assert Countdown.mode() == :severance
    end
  end

  describe "phase_for_remaining/1" do
    test "returns gentle for 30 to 16 minutes" do
      assert Countdown.phase_for_remaining(30) == :gentle
      assert Countdown.phase_for_remaining(16) == :gentle
    end

    test "returns aggressive for 15 to 6 minutes" do
      assert Countdown.phase_for_remaining(15) == :aggressive
      assert Countdown.phase_for_remaining(6) == :aggressive
    end

    test "returns final for 5 to 1 minutes" do
      assert Countdown.phase_for_remaining(5) == :final
      assert Countdown.phase_for_remaining(1) == :final
    end

    test "returns shutdown for 0 or negative" do
      assert Countdown.phase_for_remaining(0) == :shutdown
      assert Countdown.phase_for_remaining(-1) == :shutdown
    end
  end

  describe "tick_interval_ms/1" do
    test "gentle phase ticks every 5 minutes" do
      assert Countdown.tick_interval_ms(:gentle) == 5 * 60 * 1000
    end

    test "aggressive phase ticks every 2 minutes" do
      assert Countdown.tick_interval_ms(:aggressive) == 2 * 60 * 1000
    end

    test "final phase ticks every 1 minute" do
      assert Countdown.tick_interval_ms(:final) == 60 * 1000
    end
  end

  describe "weekend detection" do
    test "is_weekend/1 returns true for Saturday and Sunday" do
      # 2026-03-28 is a Saturday
      assert Countdown.is_weekend(~D[2026-03-28]) == true
      # 2026-03-29 is a Sunday
      assert Countdown.is_weekend(~D[2026-03-29]) == true
    end

    test "is_weekend/1 returns false for weekdays" do
      # 2026-03-26 is a Thursday
      assert Countdown.is_weekend(~D[2026-03-26]) == false
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/severance
mix test test/severance/countdown_test.exs
```

Expected: compilation error — `Severance.Countdown` doesn't exist.

- [ ] **Step 3: Write `lib/severance/countdown.ex`**

```elixir
defmodule Severance.Countdown do
  @moduledoc """
  GenServer that manages the shutdown countdown state machine.

  Phases: waiting -> gentle -> aggressive -> final -> shutdown/overtime -> done

  Sleeps until T-30 before the configured shutdown time, then ticks
  through phases with escalating notifications and tmux status updates.
  On weekends, hard shutdown is disabled regardless of mode.
  """

  use GenServer

  alias Severance.Notifier
  alias Severance.Tmux

  @gentle_interval_ms 5 * 60 * 1000
  @aggressive_interval_ms 2 * 60 * 1000
  @final_interval_ms 60 * 1000
  @overtime_burst_interval_ms 5 * 1000
  @overtime_burst_count 12
  @stale_threshold_minutes 15

  defstruct [
    :shutdown_time,
    :original_tmux_status,
    mode: :severance,
    phase: :waiting
  ]

  # --- Public API ---

  @doc """
  Starts the countdown GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    shutdown_time = Keyword.fetch!(opts, :shutdown_time)
    GenServer.start_link(__MODULE__, shutdown_time, name: __MODULE__)
  end

  @doc """
  Activates the Overtime Protocol. The daemon will send annoying
  notifications at T-0 instead of shutting down the machine.
  """
  @spec overtime() :: :ok
  def overtime do
    GenServer.call(__MODULE__, :overtime)
  end

  @doc """
  Returns the current mode (`:severance` or `:overtime`).
  """
  @spec mode() :: :severance | :overtime
  def mode do
    GenServer.call(__MODULE__, :mode)
  end

  @doc """
  Returns the phase for a given number of minutes remaining.
  """
  @spec phase_for_remaining(integer()) :: :gentle | :aggressive | :final | :shutdown
  def phase_for_remaining(minutes) when minutes > 15, do: :gentle
  def phase_for_remaining(minutes) when minutes > 5, do: :aggressive
  def phase_for_remaining(minutes) when minutes > 0, do: :final
  def phase_for_remaining(_minutes), do: :shutdown

  @doc """
  Returns the tick interval in milliseconds for a given phase.
  """
  @spec tick_interval_ms(:gentle | :aggressive | :final) :: non_neg_integer()
  def tick_interval_ms(:gentle), do: @gentle_interval_ms
  def tick_interval_ms(:aggressive), do: @aggressive_interval_ms
  def tick_interval_ms(:final), do: @final_interval_ms

  @doc """
  Returns true if the given date falls on a weekend.
  """
  @spec is_weekend(Date.t()) :: boolean()
  def is_weekend(date) do
    Date.day_of_week(date) in [6, 7]
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(shutdown_time) do
    state = %__MODULE__{shutdown_time: shutdown_time}
    schedule_countdown_start(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:overtime, _from, state) do
    {:reply, :ok, %{state | mode: :overtime}}
  end

  @impl true
  def handle_call(:mode, _from, state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_info(:start_countdown, state) do
    original_status = Tmux.capture_status_right()
    state = %{state | original_tmux_status: original_status, phase: :gentle}
    tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    minutes_left = minutes_remaining(state.shutdown_time)
    phase = phase_for_remaining(minutes_left)
    state = %{state | phase: phase}

    case phase do
      :shutdown ->
        handle_shutdown(state)
        {:noreply, %{state | phase: :done}}

      _ ->
        Notifier.send_countdown(minutes_left, effective_mode(state), phase)
        Tmux.set_status_right(Tmux.countdown_status(minutes_left, phase, state.original_tmux_status))

        if phase == :aggressive and minutes_left == 15 do
          send_stale_pane_warnings()
        end

        schedule_tick(phase)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:overtime_burst, 0}, state) do
    Tmux.set_status_right(state.original_tmux_status)
    {:noreply, %{state | phase: :done}}
  end

  @impl true
  def handle_info({:overtime_burst, remaining}, state) do
    Notifier.send_overtime_burst()
    Process.send_after(self(), {:overtime_burst, remaining - 1}, @overtime_burst_interval_ms)
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_countdown_start(state) do
    ms = ms_until_countdown_start(state.shutdown_time)

    if ms > 0 do
      Process.send_after(self(), :start_countdown, ms)
    else
      send(self(), :start_countdown)
    end
  end

  defp schedule_tick(phase) do
    Process.send_after(self(), :tick, tick_interval_ms(phase))
  end

  defp tick(state) do
    send(self(), :tick)
    state
  end

  defp handle_shutdown(state) do
    case effective_mode(state) do
      :severance ->
        Notifier.send_countdown(0, :severance, :final)
        Tmux.set_status_right(state.original_tmux_status)
        Severance.System.adapter().shutdown_machine()

      :overtime ->
        Process.send_after(self(), {:overtime_burst, @overtime_burst_count}, 0)
    end
  end

  defp effective_mode(state) do
    if is_weekend(DateTime.to_date(local_now())) do
      :overtime
    else
      state.mode
    end
  end

  defp minutes_remaining(shutdown_time) do
    now = DateTime.to_time(local_now())
    Time.diff(shutdown_time, now, :minute)
  end

  defp ms_until_countdown_start(shutdown_time) do
    countdown_start = Time.add(shutdown_time, -30, :minute)
    now = DateTime.to_time(local_now())
    Time.diff(countdown_start, now, :millisecond)
  end

  defp local_now do
    tz = Application.get_env(:severance, :timezone, "America/Los_Angeles")
    DateTime.now!(tz)
  end

  defp send_stale_pane_warnings do
    @stale_threshold_minutes
    |> Tmux.stale_panes()
    |> Enum.each(&Notifier.send_stale_pane/1)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/severance
mix test test/severance/countdown_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Format and lint**

```bash
cd ~/severance
mix format lib/severance/countdown.ex test/severance/countdown_test.exs
mix credo --strict
```

- [ ] **Step 6: Commit**

```bash
cd ~/severance
git add lib/severance/countdown.ex test/severance/countdown_test.exs
git commit -m "Add countdown GenServer with phase state machine"
```

---

## Task 6: CLI Module

**Files:**
- Create: `lib/severance/cli.ex`
- Create: `test/severance/cli_test.exs`

- [ ] **Step 1: Write the failing tests in `test/severance/cli_test.exs`**

```elixir
defmodule Severance.CLITest do
  use ExUnit.Case, async: true

  alias Severance.CLI

  describe "parse_args/1" do
    test "empty args returns :start" do
      assert CLI.parse_args([]) == :start
    end

    test "otp arg returns :overtime" do
      assert CLI.parse_args(["otp"]) == :overtime
    end

    test "shutdown-time flag returns start with custom time" do
      assert CLI.parse_args(["--shutdown-time", "17:00"]) ==
               {:start, shutdown_time: ~T[17:00:00]}
    end

    test "unknown args returns :start" do
      assert CLI.parse_args(["something-else"]) == :start
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/severance
mix test test/severance/cli_test.exs
```

Expected: compilation error — `Severance.CLI` doesn't exist.

- [ ] **Step 3: Write `lib/severance/cli.ex`**

```elixir
defmodule Severance.CLI do
  @moduledoc """
  Handles CLI argument parsing and the Overtime Protocol RPC connection.

  ## Usage

      severance                     # Start the daemon
      severance --shutdown-time HH:MM  # Start with custom shutdown time
      severance otp                 # Activate Overtime Protocol on running daemon
  """

  @doc """
  Parses command-line arguments into an action atom.
  """
  @spec parse_args([String.t()]) :: :start | {:start, keyword()} | :overtime
  def parse_args(["otp" | _rest]), do: :overtime

  def parse_args(["--shutdown-time", time_str | _rest]) do
    {:ok, time} = Time.from_iso8601(time_str <> ":00")
    {:start, shutdown_time: time}
  end

  def parse_args(_args), do: :start

  @doc """
  Connects to the running severance node and activates the Overtime Protocol.
  """
  @spec run_overtime() :: :ok | {:error, String.t()}
  def run_overtime do
    hostname = node_hostname()
    target = :"severance@#{hostname}"
    cli_name = :"severance_cli_#{:rand.uniform(100_000)}@#{hostname}"

    Node.start(cli_name, :shortnames)
    Node.set_cookie(Node.self(), cookie())

    case Node.connect(target) do
      true ->
        :rpc.call(target, Severance.Countdown, :overtime, [])
        IO.puts("Overtime Protocol activated. No shutdown today — but you'll hear about it.")
        :ok

      false ->
        IO.puts("Could not connect to severance daemon. Is it running?")
        {:error, "connection failed"}
    end
  end

  defp node_hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

  defp cookie do
    Node.get_cookie()
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/severance
mix test test/severance/cli_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Format and lint**

```bash
cd ~/severance
mix format lib/severance/cli.ex test/severance/cli_test.exs
mix credo --strict
```

- [ ] **Step 6: Commit**

```bash
cd ~/severance
git add lib/severance/cli.ex test/severance/cli_test.exs
git commit -m "Add CLI module with arg parsing and OTP RPC"
```

---

## Task 7: Release Configuration and Main Entrypoint

**Files:**
- Create: `rel/env.sh.eex`
- Modify: `lib/severance.ex`
- Modify: `lib/severance/application.ex`

- [ ] **Step 1: Create `rel/env.sh.eex`**

```bash
mkdir -p ~/severance/rel
```

```eex
#!/bin/sh

export RELEASE_DISTRIBUTION=sname
export RELEASE_NODE="severance"
```

- [ ] **Step 2: Create `rel/overlays/bin/sev`**

```bash
mkdir -p ~/severance/rel/overlays/bin
```

Write `rel/overlays/bin/sev`:

```bash
#!/bin/bash
# Severance CLI wrapper
#
# Usage:
#   sev              — start the daemon
#   sev otp          — activate Overtime Protocol
#   sev stop         — stop the daemon

RELEASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-start}" in
  otp)
    exec "$RELEASE_DIR/bin/severance" eval "Severance.CLI.run_overtime()"
    ;;
  start|"")
    # Check if already running via the release pid command
    if "$RELEASE_DIR/bin/severance" pid > /dev/null 2>&1; then
      echo "Severance is already running."
      exit 0
    fi
    exec "$RELEASE_DIR/bin/severance" start
    ;;
  *)
    # Pass through to the release (stop, restart, pid, etc.)
    exec "$RELEASE_DIR/bin/severance" "$@"
    ;;
esac
```

- [ ] **Step 3: Update `mix.exs` release config to include overlays**

```elixir
defp releases do
  [
    severance: [
      steps: [:assemble],
      include_executables_for: [:unix],
      overlays: ["rel/overlays"]
    ]
  ]
end
```

- [ ] **Step 4: Build the release and test it**

```bash
cd ~/severance
MIX_ENV=prod mix release severance
```

Expected: release built to `_build/prod/rel/severance/`.

- [ ] **Step 5: Copy release to `~/bin/severance`**

```bash
rm -rf ~/bin/severance
cp -r ~/severance/_build/prod/rel/severance ~/bin/severance
chmod +x ~/bin/severance/bin/sev
ln -sf ~/bin/severance/bin/sev ~/bin/sev
```

The user calls `sev` to start and `sev otp` for overtime.

- [ ] **Step 6: Commit**

```bash
cd ~/severance
git add rel/ mix.exs
git commit -m "Add release config and CLI wrapper"
```

---

## Task 8: LaunchAgent and Deployment

**Files:**
- Create: `rel/com.severance.daemon.plist`

- [ ] **Step 1: Create the launchd plist at `rel/com.severance.daemon.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.severance.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/kylesanclemente/bin/severance/bin/sev</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/severance.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/severance.err</string>
</dict>
</plist>
```

- [ ] **Step 2: Install the plist**

```bash
cp ~/severance/rel/com.severance.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.severance.daemon.plist
```

- [ ] **Step 3: Verify the daemon starts**

```bash
launchctl list | grep severance
cat /tmp/severance.log
```

Expected: severance appears in the list, log shows "Severance daemon running."

- [ ] **Step 4: Test the OTP command**

```bash
~/bin/severance/bin/sev otp
```

Expected: "Overtime Protocol activated. No shutdown today — but you'll hear about it."

- [ ] **Step 5: Commit everything**

```bash
cd ~/severance
git add rel/com.severance.daemon.plist
git commit -m "Add launchd plist for login startup"
```

- [ ] **Step 6: Track binary with vcsh macos**

```bash
vcsh macos add ~/bin/severance
vcsh macos commit -m "Add severance release binary"
```

---

## Task 9: Integration Test

**Files:**
- Create: `test/severance/integration_test.exs`

- [ ] **Step 1: Write integration test in `test/severance/integration_test.exs`**

```elixir
defmodule Severance.IntegrationTest do
  use ExUnit.Case, async: false

  alias Severance.Countdown

  test "full countdown lifecycle with overtime mode" do
    # Start with a shutdown time 1 second from now so we can test quickly
    soon = Time.add(Time.utc_now(), 32, :second)

    start_supervised!({Countdown, shutdown_time: soon})

    # Verify default mode
    assert Countdown.mode() == :severance

    # Switch to overtime
    assert :ok = Countdown.overtime()
    assert Countdown.mode() == :overtime

    # The GenServer should be alive and in waiting or gentle phase
    assert Process.alive?(Process.whereis(Countdown))
  end

  test "overtime/0 returns ok when called multiple times" do
    start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})

    assert :ok = Countdown.overtime()
    assert :ok = Countdown.overtime()
    assert Countdown.mode() == :overtime
  end
end
```

- [ ] **Step 2: Run the full test suite**

```bash
cd ~/severance
mix test
```

Expected: all tests pass.

- [ ] **Step 3: Format, lint, check types**

```bash
cd ~/severance
mix format
mix credo --strict
mix dialyzer
```

- [ ] **Step 4: Commit**

```bash
cd ~/severance
git add test/severance/integration_test.exs
git commit -m "Add integration tests"
```

---

## Task 10: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
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

## Requirements

- Elixir 1.19+ / OTP 28+
- macOS (uses `osascript` for notifications and shutdown)
- tmux (for status bar and stale pane detection)
```

- [ ] **Step 2: Commit**

```bash
cd ~/severance
git add README.md
git commit -m "Add README"
```
