defmodule Severance.CountdownTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Severance.Countdown

  defmodule RecordingSystem do
    @moduledoc false
    @behaviour Severance.System

    @impl true
    def notify(_title, _message, _sound), do: :ok

    @impl true
    def shutdown_machine, do: :ok

    @impl true
    def tmux_cmd(["show-option", "-gv", "status-right"] = args) do
      record(args)
      value = Application.get_env(:severance, :tmux_status_right, "")
      {value, 0}
    end

    @impl true
    def tmux_cmd(args) do
      record(args)
      {"", 0}
    end

    defp record(args) do
      case Application.get_env(:severance, :tmux_recorder) do
        nil -> :ok
        pid when is_pid(pid) -> send(pid, {:tmux_cmd, args})
      end
    end
  end

  @frozen_now ~N[2026-04-09 10:00:00]

  setup do
    frozen = @frozen_now
    Application.put_env(:severance, :now_fn, fn -> frozen end)
    on_exit(fn -> Application.delete_env(:severance, :now_fn) end)
    :ok
  end

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

  describe "status/0" do
    test "returns status map with mode, phase, shutdown_time, and minutes_remaining" do
      future = @frozen_now |> NaiveDateTime.add(3600) |> NaiveDateTime.to_time()
      start_supervised!({Countdown, shutdown_time: future})

      status = Countdown.status()

      assert status.mode == :severance
      assert status.phase == :waiting
      assert status.shutdown_time == future
      assert is_integer(status.minutes_remaining)
    end

    test "reflects overtime mode" do
      future = @frozen_now |> NaiveDateTime.add(3600) |> NaiveDateTime.to_time()
      start_supervised!({Countdown, shutdown_time: future})
      Countdown.overtime()

      status = Countdown.status()

      assert status.mode == :overtime
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

  describe "retry_shutdown" do
    test "retries shutdown and schedules another retry indefinitely" do
      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[00:00:01]})

        # Let late_start trigger handle_shutdown which fires
        # the first shutdown + schedules :retry_shutdown
        Process.sleep(100)

        state = :sys.get_state(pid)
        assert state.phase == :done

        # Send :retry_shutdown — it should call shutdown_machine
        # and schedule another :retry_shutdown (no stop condition)
        send(pid, :retry_shutdown)
        Process.sleep(50)

        assert Process.alive?(pid)
      end)
    end
  end

  describe "past_shutdown?/1" do
    test "returns true for a time in the past" do
      assert Countdown.past_shutdown?(~T[00:00:01]) == true
    end

    test "returns false for a time in the future" do
      refute Countdown.past_shutdown?(~T[23:59:59])
    end
  end

  describe "late start" do
    test "attempts shutdown when started after shutdown time on a weekday" do
      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[00:00:01]})

        # Let the GenServer process :late_start and handle_shutdown
        Process.sleep(100)

        assert Process.alive?(pid)

        # In severance mode on a weekday, late start should call
        # handle_shutdown which sets phase to :done
        state = :sys.get_state(pid)
        assert state.phase == :done
      end)
    end

    test "fires overtime burst instead of shutdown when in overtime mode" do
      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[00:00:01], mode: :overtime})

        # Let the GenServer process :late_start and begin the burst
        Process.sleep(100)

        assert Process.alive?(pid)

        # The test adapter sends :shutdown_machine to self() (the GenServer)
        # when shutdown_machine/0 is called. In overtime mode,
        # shutdown_machine should never be called.
        {:messages, messages} = Process.info(pid, :messages)
        refute :shutdown_machine in messages
      end)
    end
  end

  describe "overtime notification toggle" do
    setup do
      original = Application.get_env(:severance, :overtime_notifications)

      on_exit(fn ->
        Application.put_env(:severance, :overtime_notifications, original || true)
      end)

      :ok
    end

    test "skips overtime burst when overtime_notifications is false (late start in overtime mode)" do
      Application.put_env(:severance, :overtime_notifications, false)

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[00:00:01], mode: :overtime})
        Process.sleep(100)

        assert Process.alive?(pid)

        # With notifications disabled, late_start should immediately finish
        # and set phase to :done without scheduling any burst
        state = :sys.get_state(pid)
        assert state.phase == :done
      end)
    end

    test "fires overtime burst when overtime_notifications is true (late start in overtime mode)" do
      Application.put_env(:severance, :overtime_notifications, true)

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[00:00:01], mode: :overtime})
        Process.sleep(100)

        assert Process.alive?(pid)

        # With notifications enabled, the burst is in progress (takes 60s to
        # complete), so phase should NOT be :done yet
        state = :sys.get_state(pid)
        refute state.phase == :done
      end)
    end
  end

  describe "waiting phase status updates" do
    test "captures the original tmux status on init" do
      future = @frozen_now |> NaiveDateTime.add(4 * 3600) |> NaiveDateTime.to_time()

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        state = :sys.get_state(pid)
        # Test adapter returns empty string for show-option
        assert state.original_tmux_status == ""
      end)
    end

    test "keeps state in waiting phase while polling" do
      future = @frozen_now |> NaiveDateTime.add(4 * 3600) |> NaiveDateTime.to_time()

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        send(pid, :check_countdown_start)
        Process.sleep(50)

        state = :sys.get_state(pid)
        assert state.phase == :waiting
        assert state.original_tmux_status == ""
      end)
    end

    test "survives init when tmux command fails and leaves original unset" do
      # Daemon starts at login before any tmux server exists. capture must
      # not crash the GenServer, and original_tmux_status must stay nil
      # so a later restore does not wipe the user's real status-right.
      future = @frozen_now |> NaiveDateTime.add(4 * 3600) |> NaiveDateTime.to_time()

      original_adapter = Application.get_env(:severance, :system_adapter)
      Application.put_env(:severance, :system_adapter, Severance.TmuxTest.FailingSystem)

      on_exit(fn ->
        if original_adapter do
          Application.put_env(:severance, :system_adapter, original_adapter)
        else
          Application.delete_env(:severance, :system_adapter)
        end
      end)

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        assert Process.alive?(pid)
        state = :sys.get_state(pid)
        assert state.phase == :waiting
        assert state.original_tmux_status == nil
      end)
    end
  end

  describe "active phase status refresh" do
    setup do
      original_adapter = Application.get_env(:severance, :system_adapter)
      Application.put_env(:severance, :system_adapter, Severance.CountdownTest.RecordingSystem)
      Application.put_env(:severance, :tmux_recorder, self())

      on_exit(fn ->
        Application.delete_env(:severance, :tmux_recorder)

        if original_adapter do
          Application.put_env(:severance, :system_adapter, original_adapter)
        else
          Application.delete_env(:severance, :system_adapter)
        end
      end)

      :ok
    end

    test "refresh_status updates tmux status during gentle phase with current minutes" do
      future = @frozen_now |> NaiveDateTime.add(25 * 60) |> NaiveDateTime.to_time()

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        :sys.replace_state(pid, fn s ->
          %{s | phase: :gentle, original_tmux_status: "orig"}
        end)

        drain_tmux()
        send(pid, :refresh_status)
        Process.sleep(50)

        assert_received {:tmux_cmd, ["set-option", "-g", "status-right", status]}
        assert status =~ "sev:25m"
      end)
    end

    test "refresh_status uses derived phase color, not stale state phase" do
      # State still says :gentle from the last tick, but minutes_left has
      # crossed into :aggressive. The refreshed banner must reflect the
      # current phase (red+blink), not the stale gentle color.
      future = @frozen_now |> NaiveDateTime.add(12 * 60) |> NaiveDateTime.to_time()

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        :sys.replace_state(pid, fn s ->
          %{s | phase: :gentle, original_tmux_status: ""}
        end)

        drain_tmux()
        send(pid, :refresh_status)
        Process.sleep(50)

        assert_received {:tmux_cmd, ["set-option", "-g", "status-right", status]}
        assert status =~ "colour196"
        assert status =~ "sev:12m"
      end)
    end

    test "refresh_status skips tmux update when minutes_left has reached shutdown" do
      future = @frozen_now |> NaiveDateTime.add(30) |> NaiveDateTime.to_time()

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        :sys.replace_state(pid, fn s ->
          %{s | phase: :final, original_tmux_status: ""}
        end)

        drain_tmux()
        send(pid, :refresh_status)
        Process.sleep(50)

        refute_received {:tmux_cmd, ["set-option" | _]}
      end)
    end

    test "refresh_status is a no-op during waiting phase" do
      future = @frozen_now |> NaiveDateTime.add(4 * 3600) |> NaiveDateTime.to_time()

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        drain_tmux()
        send(pid, :refresh_status)
        Process.sleep(50)

        refute_received {:tmux_cmd, ["set-option" | _]}
      end)
    end

    test "refresh_status re-captures status-right so external edits survive the minute refresh" do
      # If another tmux plugin or the user rewrites status-right during the
      # countdown, the minute refresh must read the current value (and
      # strip our own banner from it) before rewriting. Otherwise we clobber
      # their update with whatever original_tmux_status was captured earlier.
      future = @frozen_now |> NaiveDateTime.add(25 * 60) |> NaiveDateTime.to_time()

      Application.put_env(:severance, :tmux_status_right, "EXTERNAL-UPDATE")
      on_exit(fn -> Application.delete_env(:severance, :tmux_status_right) end)

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        :sys.replace_state(pid, fn s ->
          %{s | phase: :gentle, original_tmux_status: "STALE"}
        end)

        drain_tmux()
        send(pid, :refresh_status)
        Process.sleep(50)

        assert_received {:tmux_cmd, ["show-option", "-gv", "status-right"]}
        assert_received {:tmux_cmd, ["set-option", "-g", "status-right", new_status]}
        assert new_status =~ "EXTERNAL-UPDATE"
        refute new_status =~ "STALE"
      end)
    end

    test "refresh_status reschedules itself during an active phase" do
      # Override the refresh interval so the test does not have to wait a
      # real minute between refresh cycles.
      Application.put_env(:severance, :status_refresh_ms, 50)
      on_exit(fn -> Application.delete_env(:severance, :status_refresh_ms) end)

      future = @frozen_now |> NaiveDateTime.add(25 * 60) |> NaiveDateTime.to_time()

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        :sys.replace_state(pid, fn s ->
          %{s | phase: :gentle, original_tmux_status: ""}
        end)

        drain_tmux()
        send(pid, :refresh_status)
        Process.sleep(200)

        # First fire plus at least one self-reschedule should produce
        # multiple status updates.
        refresh_count = count_tmux_refreshes()
        assert refresh_count >= 2
      end)
    end
  end

  describe "terminate cleanup" do
    setup do
      dir = Path.join(System.tmp_dir!(), "severance_term_#{System.unique_integer([:positive])}")
      log_file = Path.join(dir, "activity.log")
      Application.put_env(:severance, :log_file, log_file)

      original_adapter = Application.get_env(:severance, :system_adapter)
      Application.put_env(:severance, :system_adapter, Severance.CountdownTest.RecordingSystem)
      Application.put_env(:severance, :tmux_recorder, self())

      on_exit(fn ->
        Application.delete_env(:severance, :log_file)
        Application.delete_env(:severance, :activity_log_started_at)
        Application.delete_env(:severance, :tmux_recorder)

        if original_adapter do
          Application.put_env(:severance, :system_adapter, original_adapter)
        else
          Application.delete_env(:severance, :system_adapter)
        end

        File.rm_rf!(dir)
      end)

      %{log_file: log_file}
    end

    test "restores original status-right when stopped during waiting phase" do
      Application.put_env(:severance, :activity_log_started_at, @frozen_now)
      future = @frozen_now |> NaiveDateTime.add(4 * 3600) |> NaiveDateTime.to_time()

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        :sys.replace_state(pid, fn state ->
          %{state | original_tmux_status: "MY-ORIGINAL"}
        end)

        GenServer.stop(pid)
        Process.sleep(50)

        assert_received {:tmux_cmd, ["set-option", "-g", "status-right", "MY-ORIGINAL"]}
      end)
    end

    test "does not touch tmux when terminating after handle_shutdown already restored" do
      future = @frozen_now |> NaiveDateTime.add(4 * 3600) |> NaiveDateTime.to_time()

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: future})
        Process.sleep(50)

        :sys.replace_state(pid, fn state ->
          %{state | original_tmux_status: "MY-ORIGINAL", phase: :done}
        end)

        # Drain any pending tmux_cmd messages from init
        drain_tmux()

        GenServer.stop(pid)
        Process.sleep(50)

        refute_received {:tmux_cmd, ["set-option", "-g", "status-right", "MY-ORIGINAL"]}
      end)
    end
  end

  describe "check_countdown_start poll" do
    test "stays in waiting when countdown start is in the future" do
      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})
        send(pid, :check_countdown_start)
        Process.sleep(100)

        state = :sys.get_state(pid)
        assert state.phase == :waiting
      end)
    end

    test "transitions to gentle when countdown start time has passed" do
      # Start with far-future time so init stays in :waiting,
      # then swap shutdown_time to 20min from now (countdown window active)
      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})
        Process.sleep(50)

        frozen_time = NaiveDateTime.to_time(@frozen_now)
        countdown_active_time = Time.add(frozen_time, 20, :minute)

        :sys.replace_state(pid, fn state ->
          %{state | shutdown_time: countdown_active_time}
        end)

        send(pid, :check_countdown_start)
        Process.sleep(100)

        state = :sys.get_state(pid)
        assert state.phase == :gentle
      end)
    end

    test "triggers late_start when past shutdown time" do
      # Start with far-future time so init stays in :waiting,
      # then swap to a past time and let the poll detect it
      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})
        Process.sleep(50)

        :sys.replace_state(pid, fn state ->
          %{state | shutdown_time: ~T[00:00:01]}
        end)

        send(pid, :check_countdown_start)
        Process.sleep(100)

        state = :sys.get_state(pid)
        assert state.phase == :done
      end)
    end
  end

  describe "weekend detection" do
    test "weekend?/1 returns true for Saturday and Sunday" do
      # 2026-03-28 is a Saturday
      assert Countdown.weekend?(~D[2026-03-28]) == true
      # 2026-03-29 is a Sunday
      assert Countdown.weekend?(~D[2026-03-29]) == true
    end

    test "weekend?/1 returns false for weekdays" do
      # 2026-03-26 is a Thursday
      assert Countdown.weekend?(~D[2026-03-26]) == false
    end
  end

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

    test "terminate logs a stopped event on normal shutdown", %{log_file: log_file} do
      Application.put_env(:severance, :activity_log_started_at, @frozen_now)
      pid = start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})

      GenServer.stop(pid)
      Process.sleep(50)

      assert File.exists?(log_file)
      contents = File.read!(log_file)
      assert contents =~ "stopped"
      assert contents =~ "duration_minutes="
    end

    test "terminate does not log stopped on crash", %{log_file: log_file} do
      pid = start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})

      Process.exit(pid, :kill)
      Process.sleep(50)

      refute File.exists?(log_file)
    end
  end

  defp drain_tmux do
    receive do
      {:tmux_cmd, _} -> drain_tmux()
    after
      20 -> :ok
    end
  end

  defp count_tmux_refreshes(count \\ 0) do
    receive do
      {:tmux_cmd, ["set-option", "-g", "status-right", _]} ->
        count_tmux_refreshes(count + 1)
    after
      20 -> count
    end
  end
end
