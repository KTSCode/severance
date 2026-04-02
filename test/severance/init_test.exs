defmodule Severance.InitTest do
  use ExUnit.Case, async: false

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
    test "prefers __BURRITO_BIN_PATH when set" do
      original = System.get_env("__BURRITO_BIN_PATH")

      try do
        System.put_env("__BURRITO_BIN_PATH", "/usr/local/bin/sev")
        assert Init.detect_binary_path() == "/usr/local/bin/sev"
      after
        if original,
          do: System.put_env("__BURRITO_BIN_PATH", original),
          else: System.delete_env("__BURRITO_BIN_PATH")
      end
    end

    test "falls back to System.find_executable when not in Burrito" do
      original = System.get_env("__BURRITO_BIN_PATH")

      try do
        System.delete_env("__BURRITO_BIN_PATH")
        path = Init.detect_binary_path()
        assert is_binary(path)
        refute String.contains?(path, ".burrito")
      after
        if original, do: System.put_env("__BURRITO_BIN_PATH", original)
      end
    end
  end
end
