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
