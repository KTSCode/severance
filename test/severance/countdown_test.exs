defmodule Severance.CountdownTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  describe "status/0" do
    test "returns status map with mode, phase, shutdown_time, and minutes_remaining" do
      future = NaiveDateTime.local_now() |> NaiveDateTime.add(3600) |> NaiveDateTime.to_time()
      start_supervised!({Countdown, shutdown_time: future})

      status = Countdown.status()

      assert status.mode == :severance
      assert status.phase == :waiting
      assert status.shutdown_time == future
      assert is_integer(status.minutes_remaining)
    end

    test "reflects overtime mode" do
      future = NaiveDateTime.local_now() |> NaiveDateTime.add(3600) |> NaiveDateTime.to_time()
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

  describe "retry_delay_ms/1" do
    test "returns exponential backoff delays" do
      assert Countdown.retry_delay_ms(0) == 5_000
      assert Countdown.retry_delay_ms(1) == 10_000
      assert Countdown.retry_delay_ms(2) == 20_000
      assert Countdown.retry_delay_ms(3) == 40_000
    end

    test "caps at max retries" do
      assert Countdown.retry_delay_ms(4) == :stop
      assert Countdown.retry_delay_ms(10) == :stop
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
    test "fires overtime burst instead of shutdown when started after shutdown time" do
      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[00:00:01]})

        # Let the GenServer process :late_start and begin the burst
        Process.sleep(100)

        assert Process.alive?(pid)

        # The test adapter sends :shutdown_machine to self() (the GenServer)
        # when shutdown_machine/0 is called. If late start works correctly,
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

    test "skips overtime burst when overtime_notifications is false (late start)" do
      Application.put_env(:severance, :overtime_notifications, false)

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[00:00:01]})
        Process.sleep(100)

        assert Process.alive?(pid)

        # With notifications disabled, late_start should immediately finish
        # and set phase to :done without scheduling any burst
        state = :sys.get_state(pid)
        assert state.phase == :done
      end)
    end

    test "fires overtime burst when overtime_notifications is true (late start)" do
      Application.put_env(:severance, :overtime_notifications, true)

      capture_log(fn ->
        pid = start_supervised!({Countdown, shutdown_time: ~T[00:00:01]})
        Process.sleep(100)

        assert Process.alive?(pid)

        # With notifications enabled, the burst is in progress (takes 60s to
        # complete), so phase should NOT be :done yet
        state = :sys.get_state(pid)
        refute state.phase == :done
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
end
