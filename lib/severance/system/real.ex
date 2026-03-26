defmodule Severance.System.Real do
  @moduledoc """
  Real system adapter. Calls osascript for notifications and shutdown,
  and tmux for status bar manipulation.
  """

  @behaviour Severance.System

  @impl true
  @doc """
  Sends a macOS notification via osascript.
  """
  @spec notify(String.t(), String.t(), String.t()) :: :ok
  def notify(title, message, sound) do
    script =
      ~s(display notification "#{message}" with title "#{title}" sound name "#{sound}")

    System.cmd("osascript", ["-e", script])
    :ok
  end

  @impl true
  @doc """
  Shuts down the machine via osascript.
  """
  @spec shutdown_machine() :: :ok
  def shutdown_machine do
    System.cmd("osascript", ["-e", ~s(tell app "System Events" to shut down)])
    :ok
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
