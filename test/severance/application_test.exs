defmodule Severance.ApplicationTest do
  use ExUnit.Case, async: false

  alias Severance.Application

  describe "cli_argv/0" do
    test "returns System.argv() when Burrito is not loaded" do
      assert Application.cli_argv() == System.argv()
    end
  end

  describe "start_daemon/0" do
    test "starts the supervisor tree" do
      # The application is already started by ExUnit, so we verify
      # the supervisor is running
      assert Process.whereis(Severance.Supervisor)
    end

    test "daemon_node_name/0 returns severance@localhost" do
      assert Application.daemon_node_name() == :severance@localhost
    end
  end

  describe "resolve_config/1" do
    setup do
      original_ot = Elixir.Application.get_env(:severance, :overtime_notifications)
      original_lf = Elixir.Application.get_env(:severance, :log_file)

      on_exit(fn ->
        Elixir.Application.put_env(:severance, :overtime_notifications, original_ot || true)

        if original_lf,
          do: Elixir.Application.put_env(:severance, :log_file, original_lf),
          else: Elixir.Application.delete_env(:severance, :log_file)
      end)

      :ok
    end

    test "uses compiled default when no opts, no config file, no env var" do
      default_time = Elixir.Application.get_env(:severance, :shutdown_time)

      nonexistent =
        Path.join(System.tmp_dir!(), "sev_no_config_#{System.unique_integer([:positive])}")

      resolved = Application.resolve_config([], config_dir: nonexistent, suppress_warning: true)

      assert resolved.shutdown_time == default_time
      assert resolved.overtime_notifications == true
    end

    test "config file values override compiled defaults" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "18:00", overtime_notifications: false})

      File.write!(Path.join(dir, "config.exs"), config_content)

      resolved = Application.resolve_config([], config_dir: dir)

      assert resolved.shutdown_time == ~T[18:00:00]
      assert resolved.overtime_notifications == false
    end

    test "env var overrides config file" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "18:00", overtime_notifications: true})

      File.write!(Path.join(dir, "config.exs"), config_content)

      System.put_env("SEVERANCE_SHUTDOWN_TIME", "19:30")
      on_exit(fn -> System.delete_env("SEVERANCE_SHUTDOWN_TIME") end)

      resolved = Application.resolve_config([], config_dir: dir)

      assert resolved.shutdown_time == ~T[19:30:00]
    end

    test "CLI opts override env var and config file" do
      System.put_env("SEVERANCE_SHUTDOWN_TIME", "19:30")
      on_exit(fn -> System.delete_env("SEVERANCE_SHUTDOWN_TIME") end)

      resolved = Application.resolve_config([shutdown_time: ~T[20:00:00]], suppress_warning: true)

      assert resolved.shutdown_time == ~T[20:00:00]
    end

    test "stores overtime_notifications in Application env" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "17:00", overtime_notifications: false})

      File.write!(Path.join(dir, "config.exs"), config_content)

      Application.resolve_config([], config_dir: dir)

      assert Elixir.Application.get_env(:severance, :overtime_notifications) == false
    end

    test "resolves log_file from config file" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "17:00", overtime_notifications: true, log_file: "/custom/path/sev.log"})

      File.write!(Path.join(dir, "config.exs"), config_content)

      resolved = Application.resolve_config([], config_dir: dir)

      assert resolved.log_file == "/custom/path/sev.log"
    end

    test "uses default log_file when config file has no log_file key" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "17:00", overtime_notifications: true})

      File.write!(Path.join(dir, "config.exs"), config_content)

      resolved = Application.resolve_config([], config_dir: dir)

      assert resolved.log_file =~ ".local/state/severance/activity.log"
    end

    test "expands tilde in log_file path" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "17:00", overtime_notifications: true, log_file: "~/.local/state/severance/activity.log"})

      File.write!(Path.join(dir, "config.exs"), config_content)

      resolved = Application.resolve_config([], config_dir: dir)

      refute String.starts_with?(resolved.log_file, "~")
      assert resolved.log_file =~ ".local/state/severance/activity.log"
    end

    test "stores log_file in Application env" do
      dir = Path.join(System.tmp_dir!(), "sev_app_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      config_content =
        ~s(%{shutdown_time: "17:00", overtime_notifications: true, log_file: "/tmp/test.log"})

      File.write!(Path.join(dir, "config.exs"), config_content)

      Application.resolve_config([], config_dir: dir)

      assert Elixir.Application.get_env(:severance, :log_file) == "/tmp/test.log"
    end
  end
end
