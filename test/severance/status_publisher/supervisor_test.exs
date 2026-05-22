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
end
