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
