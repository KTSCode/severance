defmodule Severance.ConfigTest do
  use ExUnit.Case, async: true

  alias Severance.Config

  describe "defaults/0" do
    test "returns map with shutdown_time and overtime_notifications but not timezone" do
      defaults = Config.defaults()

      assert %{
               shutdown_time: "17:00",
               overtime_notifications: true
             } = defaults

      refute Map.has_key?(defaults, :timezone)
    end
  end

  describe "config_path/0" do
    test "returns path under ~/.config/severance" do
      path = Config.config_path()
      assert path =~ ".config/severance/config.exs"
      assert String.starts_with?(path, System.user_home!())
    end
  end

  describe "generate_contents/1" do
    test "generates valid Elixir term without timezone" do
      config = %{
        shutdown_time: "16:30",
        overtime_notifications: false
      }

      contents = Config.generate_contents(config)
      {result, _bindings} = Code.eval_string(contents)

      assert result == config
    end

    test "includes timezone when present in the config map" do
      config = %{
        shutdown_time: "16:30",
        timezone: "America/New_York",
        overtime_notifications: false
      }

      contents = Config.generate_contents(config)
      {result, _bindings} = Code.eval_string(contents)

      assert result == config
    end

    test "round-trips defaults" do
      contents = Config.generate_contents(Config.defaults())
      {result, _bindings} = Code.eval_string(contents)

      assert result == Config.defaults()
    end
  end

  describe "read/1" do
    test "returns {:error, :not_found} when config file missing" do
      dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")

      assert {:error, :not_found} = Config.read(dir)
    end

    test "preserves timezone from config file when present" do
      dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "config.exs"),
        ~s(%{shutdown_time: "18:00", timezone: "Europe/London", overtime_notifications: true})
      )

      assert {:ok, config} = Config.read(dir)
      assert config.timezone == "Europe/London"
    end

    test "does not inject default timezone when config file omits it" do
      dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "config.exs"),
        ~s(%{shutdown_time: "18:00", overtime_notifications: true})
      )

      assert {:ok, config} = Config.read(dir)
      refute Map.has_key?(config, :timezone)
    end
  end

  describe "write_defaults/1 + read/1 round-trip" do
    test "writes default config and reads it back" do
      dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(dir) end)

      assert :ok = Config.write_defaults(dir)
      assert {:ok, config} = Config.read(dir)
      assert config == Config.defaults()
    end

    test "creates the directory if it doesn't exist" do
      dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(dir) end)

      refute File.exists?(dir)
      assert :ok = Config.write_defaults(dir)
      assert File.exists?(dir)
    end
  end
end
