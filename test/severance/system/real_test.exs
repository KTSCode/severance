defmodule Severance.System.RealTest do
  use ExUnit.Case, async: true

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
end
