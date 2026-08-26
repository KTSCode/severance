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
    log_file: "~/.local/state/severance/activity.log",
    shutdown_on_late_start: false,
    publishers: %{}
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
    generate_contents(config, [])
  end

  @doc """
  Generates file contents with optional shape selection.

  Pass `with_tmux: true` to emit the default tmux publisher inline.
  """
  @spec generate_contents(map(), keyword()) :: String.t()
  def generate_contents(config, opts) do
    publishers_block =
      if Keyword.get(opts, :with_tmux, false) do
        tmux_publishers_block()
      else
        empty_publishers_block()
      end

    """
    %{
      shutdown_time: #{inspect(config.shutdown_time)},
      overtime_notifications: #{inspect(config.overtime_notifications)},
      log_file: #{inspect(config.log_file)},
      shutdown_on_late_start: #{inspect(config.shutdown_on_late_start)},
    #{publishers_block}
    }
    """
  end

  @doc """
  Writes the default config file to the given directory (or the default).

  Creates the directory if it doesn't exist. Idempotent — overwrites
  any existing file. Pass `with_tmux: true` to emit the default tmux publisher.
  """
  @spec write_defaults(String.t(), keyword()) :: :ok
  def write_defaults(dir \\ config_dir(), opts \\ []) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "config.exs")
    File.write!(path, generate_contents(@default_config, opts))
    :ok
  end

  defp empty_publishers_block do
    String.trim_trailing("""
      # Publishers run on the daemon and push status updates to a sink
      # (tmux user var, polybar file, dbus, etc). Add entries here keyed
      # by an atom of your choice. See docs/configuration.md for the
      # full publisher contract. Run `sev init --with-tmux` to regenerate
      # with a default tmux publisher.
      publishers: %{}
    """)
  end

  defp tmux_publishers_block do
    String.trim_trailing("""
      # Publishers run on the daemon and push status updates to a sink
      # (tmux user var, polybar file, dbus, etc). Add your own entries.
      # See docs/configuration.md for the full publisher contract.
      publishers: %{
        # Severance.StatusPublisher.Tmux.publisher/2 builds a publisher
        # that writes the formatted string to the tmux user variable
        # `@sev_countdown` once per minute. Reference it from tmux.conf:
        #   set -ag status-right "\#{@sev_countdown}"
        # Run `sev init` to print the exact paste-block for your config.
        tmux_countdown:
          Severance.StatusPublisher.Tmux.publisher("countdown", fn status ->
            # color_for_phase/2 picks a color from a 3-element list
            # ordered [waiting, gentle, final]. Pass your own list to
            # override.
            color = Severance.StatusPublisher.Tmux.Format.color_for_phase(status.phase)
            "#[fg=\#{color},bold] sev:\#{status.minutes_remaining}m #[default]"
          end)
      }
    """)
  end
end
