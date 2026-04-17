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

    test "log arg returns :log" do
      assert CLI.parse_args(["log"]) == :log
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

    test "unknown command returns error tuple" do
      assert {:error, msg} = CLI.parse_args(["something-else"])
      assert msg =~ "something-else"
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

  describe "format_status/2" do
    test "formats running daemon with no update" do
      daemon = %{
        version: Severance.Updater.current_version(),
        mode: :severance,
        phase: :waiting,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 42
      }

      update = {:ok, Severance.Updater.current_version()}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Severance v#{Severance.Updater.current_version()}"
      assert output =~ "Status:     running"
      assert output =~ "Overtime:   inactive"
      assert output =~ "Shutdown:   17:00 (42m remaining)"
      assert output =~ "Update:     up to date"
    end

    test "formats running daemon with overtime active" do
      daemon = %{
        version: Severance.Updater.current_version(),
        mode: :overtime,
        phase: :aggressive,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 10
      }

      update = {:ok, Severance.Updater.current_version()}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Overtime:   active"
    end

    test "formats running daemon with update available" do
      daemon = %{
        version: Severance.Updater.current_version(),
        mode: :severance,
        phase: :waiting,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 42
      }

      update = {:ok, "99.0.0"}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Update:     v99.0.0 available (run `sev update`)"
    end

    test "shows daemon version, not CLI version, when they differ" do
      daemon = %{
        version: "0.1.0",
        mode: :severance,
        phase: :waiting,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 42
      }

      update = {:ok, Severance.Updater.current_version()}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Severance v0.1.0"
      refute output =~ "Severance v#{Severance.Updater.current_version()}"
    end

    test "formats passed shutdown time" do
      daemon = %{
        version: Severance.Updater.current_version(),
        mode: :overtime,
        phase: :done,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: -30
      }

      update = {:ok, Severance.Updater.current_version()}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Shutdown:   17:00 (passed)"
    end

    test "formats daemon not running with failed update check" do
      output = CLI.format_status({:error, "connection failed"}, {:error, :nxdomain})

      assert output =~ "Severance v#{Severance.Updater.current_version()}"
      assert output =~ "Status:     not running"
      refute output =~ "Overtime:"
      refute output =~ "Shutdown:"
      assert output =~ "Update:     unknown (check failed)"
    end

    test "formats daemon not running with update available" do
      output = CLI.format_status({:error, "connection failed"}, {:ok, "99.0.0"})

      assert output =~ "Status:     not running"
      assert output =~ "Update:     v99.0.0 available (run `sev update`)"
    end

    test "formats daemon not running and up to date" do
      output =
        CLI.format_status(
          {:error, "connection failed"},
          {:ok, Severance.Updater.current_version()}
        )

      assert output =~ "Status:     not running"
      assert output =~ "Update:     up to date"
    end

    test "formats update check failure" do
      daemon = %{
        version: Severance.Updater.current_version(),
        mode: :severance,
        phase: :waiting,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 42
      }

      update = {:error, :nxdomain}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Update:     unknown (check failed)"
    end
  end

  describe "run_status/0" do
    test "returns :ok with not-running output and update line when daemon is not running" do
      {output, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            assert :ok = CLI.run_status()
          end)
        end)

      assert output =~ "not running"
      assert output =~ "Update:"
    end
  end

  describe "run_log/1" do
    test "prints log file contents" do
      dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")
      log_file = Path.join(dir, "activity.log")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)
      File.write!(log_file, "2026-04-15T10:00:00 started\n2026-04-15T16:45:00 overtime\n")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.run_log(log_file)
        end)

      assert output =~ "2026-04-15T10:00:00 started"
      assert output =~ "2026-04-15T16:45:00 overtime"
    end

    test "prints message when log file does not exist" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.run_log("/nonexistent/path/activity.log")
        end)

      assert output =~ "No activity log found"
    end
  end
end
