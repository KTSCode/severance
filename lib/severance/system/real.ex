defmodule Severance.System.Real do
  @moduledoc """
  Real system adapter. Calls osascript for notifications, sudo shutdown
  for machine power-off, and tmux for status bar manipulation.
  """

  @behaviour Severance.System

  require Logger

  @impl true
  @doc """
  Sends a macOS notification via osascript.
  """
  @spec notify(String.t(), String.t(), String.t()) :: :ok
  def notify(title, message, sound) do
    safe_title = escape_applescript(title)
    safe_message = escape_applescript(message)
    safe_sound = escape_applescript(sound)

    script =
      ~s(display notification "#{safe_message}" with title "#{safe_title}" sound name "#{safe_sound}")

    System.cmd("osascript", ["-e", script])
    :ok
  end

  @doc """
  Escapes a string for safe interpolation inside AppleScript double-quoted strings.

  Backslashes are escaped first, then double quotes.
  """
  @spec escape_applescript(String.t()) :: String.t()
  def escape_applescript(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(~s("), ~s(\\"))
  end

  @impl true
  @doc """
  Shuts down the machine via `sudo /sbin/shutdown`.

  Requires passwordless sudo for `/sbin/shutdown` (configured by `sev init`).
  Logs a warning on failure but always returns `:ok` — the retry mechanism
  in `Severance.Countdown` handles repeated attempts.
  """
  @spec shutdown_machine() :: :ok
  def shutdown_machine do
    case System.cmd("sudo", ["/sbin/shutdown", "-h", "now"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        Logger.warning("shutdown failed (exit #{code}): #{String.trim(output)}")
        :ok
    end
  end

  @impl true
  @doc """
  Runs a tmux command with the given args, returning output and exit code.
  """
  @spec tmux_cmd([String.t()]) :: {String.t(), non_neg_integer()}
  def tmux_cmd(args) do
    System.cmd("tmux", args, stderr_to_stdout: true)
  end
end
