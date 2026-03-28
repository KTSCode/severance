defmodule Severance.InitTest do
  use ExUnit.Case, async: true

  alias Severance.Init

  describe "plist_contents/1" do
    test "generates valid plist XML containing the given binary path" do
      plist = Init.plist_contents("/usr/local/bin/sev")

      assert plist =~ "/usr/local/bin/sev"
      assert plist =~ "<?xml version="
      assert plist =~ "com.severance.daemon"
    end

    test "contains RunAtLoad and KeepAlive keys" do
      plist = Init.plist_contents("/usr/local/bin/sev")

      assert plist =~ "<key>RunAtLoad</key>"
      assert plist =~ "<key>KeepAlive</key>"
    end

    test "contains log paths" do
      plist = Init.plist_contents("/usr/local/bin/sev")

      assert plist =~ "<key>StandardOutPath</key>"
      assert plist =~ "<key>StandardErrorPath</key>"
      assert plist =~ "severance.log"
      assert plist =~ "severance.err"
    end
  end

  describe "detect_binary_path/0" do
    test "returns a string" do
      path = Init.detect_binary_path()
      assert is_binary(path)
    end
  end
end
