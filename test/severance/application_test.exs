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
      assert Process.whereis(Severance.Supervisor) != nil
    end

    test "starts BEAM distribution as severance@hostname" do
      {:ok, hostname} = :inet.gethostname()
      expected = :"severance@#{List.to_string(hostname)}"

      # Either we claimed the name, or a real daemon already has it
      assert Node.self() == expected or Node.connect(expected)
    end
  end

  describe "resolve_config/1" do
    setup do
      original = Elixir.Application.get_env(:severance, :overtime_notifications)

      on_exit(fn ->
        Elixir.Application.put_env(:severance, :overtime_notifications, original || true)
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
  end
end
