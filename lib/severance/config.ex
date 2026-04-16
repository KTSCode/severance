defmodule Severance.Config do
  @moduledoc """
  Reads and writes the Severance user config file at
  `~/.config/severance/config.exs`.

  The config file is executed as Elixir code via `Code.eval_file/1`
  with full process privileges — it is not parsed as inert data.
  Only place this file in a directory you control.
  """

  @default_config %{
    shutdown_time: "17:00",
    overtime_notifications: true,
    log_file: Path.join([System.user_home!(), ".local", "state", "severance", "activity.log"])
  }

  @doc """
  Returns the default configuration map.
  """
  @spec defaults() :: map()
  def defaults, do: @default_config

  @doc """
  Returns the default config directory path (`~/.config/severance`).
  """
  @spec config_dir() :: String.t()
  def config_dir do
    Path.join(System.user_home!(), ".config/severance")
  end

  @doc """
  Returns the full path to the config file.
  """
  @spec config_path() :: String.t()
  def config_path do
    Path.join(config_dir(), "config.exs")
  end

  @doc """
  Reads the config file from the given directory (or the default).

  Returns `{:ok, map}` with defaults merged under file values,
  or `{:error, :not_found}` if the file doesn't exist.
  """
  @spec read(String.t()) :: {:ok, map()} | {:error, :not_found}
  def read(dir \\ config_dir()) do
    path = Path.join(dir, "config.exs")

    if File.exists?(path) do
      {config, _bindings} = Code.eval_file(path)
      {:ok, Map.merge(@default_config, config)}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Generates the file contents string for a config map.

  The output is a valid Elixir expression that evaluates to the map.
  """
  @spec generate_contents(map()) :: String.t()
  def generate_contents(config) do
    """
    %{
      shutdown_time: #{inspect(config.shutdown_time)},
      overtime_notifications: #{inspect(config.overtime_notifications)},
      log_file: #{inspect(config.log_file)}
    }
    """
  end

  @doc """
  Writes the default config file to the given directory (or the default).

  Creates the directory if it doesn't exist. Idempotent — overwrites
  any existing file.
  """
  @spec write_defaults(String.t()) :: :ok
  def write_defaults(dir \\ config_dir()) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "config.exs")
    File.write!(path, generate_contents(@default_config))
    :ok
  end
end
