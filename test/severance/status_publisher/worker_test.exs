defmodule Severance.StatusPublisher.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Severance.StatusPublisher.Worker

  setup do
    start_supervised!({Registry, keys: :unique, name: Severance.StatusPublisher.Registry})
    start_supervised!({Severance.Countdown, shutdown_time: ~T[23:59:59]})
    :ok
  end

  test "invokes publisher fn at interval" do
    parent = self()
    spec = %{fn: fn _ -> send(parent, :ran) end, interval_ms: 20}
    start_supervised!({Worker, {:test_pub, spec}})

    assert_receive :ran, 200
    assert_receive :ran, 200
  end

  test "records errors when publisher raises" do
    capture_log(fn ->
      spec = %{fn: fn _ -> raise "boom" end, interval_ms: 20}
      start_supervised!({Worker, {:bad_pub, spec}})

      Process.sleep(80)
    end)

    [{phase, reason, _at} | _] = Worker.errors(:bad_pub)
    assert phase == :publish
    assert match?({:crash, _}, reason)
  end

  test "records errors on timeout" do
    capture_log(fn ->
      spec = %{fn: fn _ -> Process.sleep(:infinity) end, interval_ms: 20}
      start_supervised!({Worker, {:slow_pub, spec}})

      Process.sleep(2_500)
    end)

    [{phase, reason, _at} | _] = Worker.errors(:slow_pub)
    assert phase == :publish
    assert reason == :timeout
  end

  test "runs teardown at init and on terminate" do
    parent = self()

    spec = %{
      fn: fn _ -> :ok end,
      teardown: fn -> send(parent, :td) end,
      interval_ms: 60_000
    }

    {:ok, pid} = Worker.start_link({:td_pub, spec})
    assert_receive :td, 100

    GenServer.stop(pid)
    assert_receive :td, 100
  end

  test "runs setup once at init" do
    parent = self()

    spec = %{
      fn: fn _ -> :ok end,
      setup: fn -> send(parent, :setup) end,
      interval_ms: 60_000
    }

    start_supervised!({Worker, {:setup_pub, spec}})
    assert_receive :setup, 100
    refute_receive :setup, 100
  end
end
