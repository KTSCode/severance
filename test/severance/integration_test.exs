defmodule Severance.IntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Severance.Countdown

  test "full countdown lifecycle with overtime mode" do
    # Start with a shutdown time far in the future
    start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})

    # Verify default mode
    assert Countdown.mode() == :severance

    # Switch to overtime
    assert :ok = Countdown.overtime()
    assert Countdown.mode() == :overtime

    # The GenServer should be alive and in waiting phase
    assert Process.alive?(Process.whereis(Countdown))
  end

  test "overtime/0 returns ok when called multiple times" do
    start_supervised!({Countdown, shutdown_time: ~T[23:59:59]})

    assert :ok = Countdown.overtime()
    assert :ok = Countdown.overtime()
    assert Countdown.mode() == :overtime
  end
end
