defmodule Severance.StatusPublisher.SupervisorTest do
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:severance, :publishers)

    on_exit(fn ->
      if original do
        Application.put_env(:severance, :publishers, original)
      else
        Application.delete_env(:severance, :publishers)
      end
    end)

    :ok
  end

  test "spawns workers from :publishers application env" do
    parent = self()

    Application.put_env(:severance, :publishers, %{
      ticker: %{fn: fn _ -> send(parent, :tick) end, interval_ms: 20}
    })

    start_supervised!({Severance.Countdown, shutdown_time: ~T[23:59:59]})
    start_supervised!(Severance.StatusPublisher.Supervisor)

    assert_receive :tick, 200
  end

  test "one bad publisher does not affect siblings" do
    parent = self()

    Application.put_env(:severance, :publishers, %{
      good: %{fn: fn _ -> send(parent, :good) end, interval_ms: 20},
      bad: %{fn: fn _ -> raise "boom" end, interval_ms: 20}
    })

    start_supervised!({Severance.Countdown, shutdown_time: ~T[23:59:59]})
    start_supervised!(Severance.StatusPublisher.Supervisor)

    assert_receive :good, 200
    assert_receive :good, 200
  end

  describe "reload/0" do
    test "swaps workers when :publishers env changes" do
      parent = self()

      Application.put_env(:severance, :publishers, %{
        old: %{fn: fn _ -> send(parent, :old_tick) end, interval_ms: 20}
      })

      start_supervised!({Severance.Countdown, shutdown_time: ~T[23:59:59]})
      start_supervised!(Severance.StatusPublisher.Supervisor)

      assert_receive :old_tick, 200

      Application.put_env(:severance, :publishers, %{
        new: %{fn: fn _ -> send(parent, :new_tick) end, interval_ms: 20}
      })

      assert {:ok, 1} = Severance.StatusPublisher.Supervisor.reload()

      # Drain any :old_tick messages already in flight before the swap landed.
      flush_old_ticks()

      refute_receive :old_tick, 100
      assert_receive :new_tick, 200
    end

    test "runs :teardown for a removed publisher" do
      parent = self()

      Application.put_env(:severance, :publishers, %{
        removed: %{
          fn: fn _ -> :ok end,
          teardown: fn -> send(parent, :torn_down) end,
          interval_ms: 20
        }
      })

      start_supervised!({Severance.Countdown, shutdown_time: ~T[23:59:59]})
      start_supervised!(Severance.StatusPublisher.Supervisor)

      Application.put_env(:severance, :publishers, %{})

      assert {:ok, 0} = Severance.StatusPublisher.Supervisor.reload()

      assert_receive :torn_down, 200
    end

    test "returns {:error, :not_running} when the supervisor is down" do
      assert {:error, :not_running} = Severance.StatusPublisher.Supervisor.reload()
    end

    defp flush_old_ticks do
      receive do
        :old_tick -> flush_old_ticks()
      after
        0 -> :ok
      end
    end
  end
end
