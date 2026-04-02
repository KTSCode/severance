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

    test "-v flag returns :version" do
      assert CLI.parse_args(["-v"]) == :version
    end

    test "--version flag returns :version" do
      assert CLI.parse_args(["--version"]) == :version
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
