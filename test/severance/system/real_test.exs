defmodule Severance.System.RealTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Severance.System.Real

  describe "escape_applescript/1" do
    test "passes through plain text unchanged" do
      assert Real.escape_applescript("Hello World") == "Hello World"
    end

    test "escapes double quotes" do
      assert Real.escape_applescript(~s(say "hello")) == ~s(say \\"hello\\")
    end

    test "escapes backslashes" do
      assert Real.escape_applescript("path\\to\\file") == "path\\\\to\\\\file"
    end

    test "escapes backslashes before quotes" do
      assert Real.escape_applescript(~s(a\\"b)) == ~s(a\\\\\\"b)
    end

    test "handles empty string" do
      assert Real.escape_applescript("") == ""
    end
  end

  describe "tmux_cmd/1" do
    test "invokes tmux via the absolute path resolved by find_executable" do
      stub(System, :find_executable, fn "tmux" -> "/opt/homebrew/bin/tmux" end)

      stub(System, :cmd, fn cmd, args, opts ->
        assert cmd == "/opt/homebrew/bin/tmux"
        assert args == ["set", "-gq", "@sev_x", "y"]
        assert opts == [stderr_to_stdout: true]
        {"", 0}
      end)

      assert Real.tmux_cmd(["set", "-gq", "@sev_x", "y"]) == {"", 0}
    end

    test "falls back to the bare command name when tmux is not on PATH" do
      stub(System, :find_executable, fn "tmux" -> nil end)

      stub(System, :cmd, fn cmd, _args, _opts ->
        assert cmd == "tmux"
        {"", 0}
      end)

      assert Real.tmux_cmd(["display-message", "x"]) == {"", 0}
    end
  end

  describe "shutdown_machine/0" do
    test "returns :ok on successful shutdown" do
      stub(System, :cmd, fn "osascript", ["-e", script], _opts ->
        assert script =~ "System Events"
        assert script =~ "shut down"
        {"", 0}
      end)

      assert Real.shutdown_machine() == :ok
    end

    test "returns :ok and logs warning when shutdown fails" do
      stub(System, :cmd, fn "osascript", ["-e", _script], _opts ->
        {"execution error", 1}
      end)

      log =
        capture_log(fn ->
          assert Real.shutdown_machine() == :ok
        end)

      assert log =~ "shutdown failed"
    end
  end
end
