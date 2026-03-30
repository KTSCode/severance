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

    test "unknown args returns :start" do
      assert CLI.parse_args(["something-else"]) == :start
    end
  end

  describe "run_stop/0" do
    test "returns error when daemon is not running" do
      assert {:error, _reason} = CLI.run_stop()
    end
  end
end
