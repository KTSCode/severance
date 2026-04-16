defmodule Severance.ActivityLogTest do
  use ExUnit.Case, async: false

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
end
