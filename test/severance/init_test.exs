defmodule Severance.InitTest do
  use ExUnit.Case, async: false

  alias Severance.Init

  describe "create_config/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "sev_init_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "writes config with empty publishers when --with-tmux not passed", %{dir: dir} do
      Severance.Config.write_defaults(dir)
      {:ok, config} = Severance.Config.read(dir)
      assert config.publishers == %{}
    end

    test "writes config with tmux publisher when --with-tmux passed", %{dir: dir} do
      Severance.Config.write_defaults(dir, with_tmux: true)
      {:ok, config} = Severance.Config.read(dir)
      assert Map.has_key?(config.publishers, :tmux_countdown)
      spec = config.publishers.tmux_countdown
      assert spec.tmux_var == "countdown"
      assert is_function(spec.fn, 1)
    end
  end

  describe "print_tmux_instructions/0" do
    setup do
      dir = Path.join(System.tmp_dir!(), "sev_init_tmux_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      conf = Path.join(dir, "tmux.conf")
      System.put_env("TMUX_CONF", conf)

      on_exit(fn ->
        System.delete_env("TMUX_CONF")
        Application.delete_env(:severance, :publishers)
        File.rm_rf!(dir)
      end)

      %{conf: conf}
    end

    test "silent when no publisher declares :tmux_var" do
      Application.put_env(:severance, :publishers, %{a: %{fn: fn _ -> :ok end}})
      output = ExUnit.CaptureIO.capture_io(fn -> Init.print_tmux_instructions() end)
      assert output == ""
    end

    test "prints paste block when var missing from conf", %{conf: conf} do
      File.write!(conf, "")

      Application.put_env(:severance, :publishers, %{
        countdown: %{fn: fn _ -> :ok end, tmux_var: "countdown"}
      })

      output = ExUnit.CaptureIO.capture_io(fn -> Init.print_tmux_instructions() end)
      assert output =~ ~s|set -ag status-right "\#{@sev_countdown}"|
      assert output =~ "status-right-length 80"
    end

    test "prints already-wired message when reference present", %{conf: conf} do
      File.write!(conf, ~s|set -ag status-right "\#{@sev_countdown}"\n|)

      Application.put_env(:severance, :publishers, %{
        countdown: %{fn: fn _ -> :ok end, tmux_var: "countdown"}
      })

      output = ExUnit.CaptureIO.capture_io(fn -> Init.print_tmux_instructions() end)
      assert output =~ "tmux.conf already wired"
    end
  end

  describe "load_publishers_env/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "sev_init_load_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn ->
        Application.delete_env(:severance, :publishers)
        File.rm_rf!(dir)
      end)

      Application.delete_env(:severance, :publishers)
      %{dir: dir}
    end

    test "populates :publishers env from the config file the init flow just wrote", %{dir: dir} do
      Severance.Config.write_defaults(dir, with_tmux: true)

      assert :ok = Init.load_publishers_env(dir)

      publishers = Application.get_env(:severance, :publishers, %{})
      assert Map.has_key?(publishers, :tmux_countdown)
      assert publishers.tmux_countdown.tmux_var == "countdown"
    end

    test "leaves :publishers env untouched when no config file exists", %{dir: dir} do
      existing = %{kept: %{fn: fn _ -> :ok end}}
      Application.put_env(:severance, :publishers, existing)

      assert :ok = Init.load_publishers_env(dir)

      assert Application.get_env(:severance, :publishers) == existing
    end
  end

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

    test "KeepAlive uses a Crashed dict so launchd restarts only on abnormal exit" do
      plist = Init.plist_contents("/usr/local/bin/sev")

      assert plist =~ ~r{<key>KeepAlive</key>\s*<dict>\s*<key>Crashed</key>\s*<true/>\s*</dict>}
    end

    test "log paths live under the user's Library/Logs, not /tmp" do
      plist = Init.plist_contents("/usr/local/bin/sev")
      home = System.user_home!()

      assert plist =~ "<key>StandardOutPath</key>"
      assert plist =~ "<key>StandardErrorPath</key>"
      assert plist =~ "#{home}/Library/Logs/severance.log"
      assert plist =~ "#{home}/Library/Logs/severance.err"
      refute plist =~ "/tmp/severance"
    end

    test "EnvironmentVariables sets a PATH that finds Homebrew tmux" do
      plist = Init.plist_contents("/usr/local/bin/sev")

      assert plist =~ "<key>EnvironmentVariables</key>"
      assert plist =~ ~r{<key>PATH</key>\s*<string>[^<]*/opt/homebrew/bin[^<]*</string>}
      assert plist =~ ~r{<key>PATH</key>\s*<string>[^<]*/usr/local/bin[^<]*</string>}
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
