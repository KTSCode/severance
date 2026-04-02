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

    test "overtime arg returns :overtime" do
      assert CLI.parse_args(["overtime"]) == :overtime
    end

    test "over_time_protocol arg returns :overtime" do
      assert CLI.parse_args(["over_time_protocol"]) == :overtime
    end

    test "shutdown-time flag returns start with custom time" do
      assert CLI.parse_args(["--shutdown-time", "17:00"]) ==
               {:start, shutdown_time: ~T[17:00:00]}
    end

    test "stop arg returns :stop" do
      assert CLI.parse_args(["stop"]) == :stop
    end

    test "init arg returns :init" do
      assert CLI.parse_args(["init"]) == :init
    end

    test "update arg returns :update" do
      assert CLI.parse_args(["update"]) == :update
    end

    test "version arg returns :version" do
      assert CLI.parse_args(["version"]) == :version
    end

    test "status arg returns :status" do
      assert CLI.parse_args(["status"]) == :status
    end

    test "-v flag returns :version" do
      assert CLI.parse_args(["-v"]) == :version
    end

    test "--version flag returns :version" do
      assert CLI.parse_args(["--version"]) == :version
    end

    test "start arg returns :start" do
      assert CLI.parse_args(["start"]) == :start
    end

    test "start with --shutdown-time returns start with opts" do
      assert CLI.parse_args(["start", "--shutdown-time", "16:00"]) ==
               {:start, shutdown_time: ~T[16:00:00]}
    end

    test "start with trailing subcommand ignores it" do
      assert CLI.parse_args(["start", "stop"]) == :start
      assert CLI.parse_args(["start", "otp"]) == :start
      assert CLI.parse_args(["start", "update"]) == :start
    end

    test "--daemon returns :daemon" do
      assert CLI.parse_args(["--daemon"]) == :daemon
    end

    test "--daemon with --shutdown-time returns daemon with opts" do
      assert CLI.parse_args(["--daemon", "--shutdown-time", "16:00"]) ==
               {:daemon, shutdown_time: ~T[16:00:00]}
    end

    test "unknown args returns :start" do
      assert CLI.parse_args(["something-else"]) == :start
    end

    test "invalid --shutdown-time returns error tuple" do
      assert {:error, _msg} = CLI.parse_args(["--shutdown-time", "lol"])
    end

    test "invalid --shutdown-time with out-of-range hours returns error tuple" do
      assert {:error, _msg} = CLI.parse_args(["--shutdown-time", "25:00"])
    end
  end

  describe "build_daemon_cmd/1" do
    test "builds command with no opts" do
      cmd = CLI.build_daemon_cmd("/usr/local/bin/sev", [])
      assert cmd =~ "/usr/local/bin/sev"
      assert cmd =~ "--daemon"
      assert cmd =~ "</dev/null"
    end

    test "includes --shutdown-time when provided" do
      cmd = CLI.build_daemon_cmd("/usr/local/bin/sev", shutdown_time: ~T[16:00:00])
      assert cmd =~ "--daemon"
      assert cmd =~ "--shutdown-time"
      assert cmd =~ "16:00"
    end

    test "shell-escapes the binary path with single quotes" do
      cmd = CLI.build_daemon_cmd("/path with spaces/sev", [])
      assert cmd =~ "'/path with spaces/sev'"
    end

    test "escapes single quotes in binary path" do
      cmd = CLI.build_daemon_cmd("/path'with'quotes/sev", [])
      assert cmd =~ "'/path'\\''with'\\''quotes/sev'"
    end
  end

  describe "start_background/2" do
    test "returns error when binary is not found" do
      assert {:error, msg} = CLI.start_background([], binary: "/nonexistent/sev")
      assert msg =~ "not found"
    end
  end

  describe "await_daemon_ready/1" do
    test "returns error after exhausting attempts when no daemon is running" do
      assert {:error, msg} = CLI.await_daemon_ready(1)
      assert msg =~ "daemon did not start"
    end
  end

  describe "daemon_running?/0" do
    test "returns false with no output when no daemon is running" do
      {io_output, log_output} =
        ExUnit.CaptureLog.with_log(fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            refute CLI.daemon_running?()
          end)
        end)

      assert io_output == ""
      assert log_output == ""
    end
  end

  describe "run_stop/0" do
    test "returns error when daemon is not running" do
      assert {:error, _reason} = CLI.run_stop()
    end
  end
end
