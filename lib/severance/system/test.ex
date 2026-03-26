defmodule Severance.System.Test do
  @moduledoc """
  Test adapter that records system calls in the calling process's
  message inbox instead of executing them.
  """

  @behaviour Severance.System

  @impl true
  @doc """
  Sends `{:notify, title, message, sound}` to the calling process.
  """
  @spec notify(String.t(), String.t(), String.t()) :: :ok
  def notify(title, message, sound) do
    send(self(), {:notify, title, message, sound})
    :ok
  end

  @impl true
  @doc """
  Sends `:shutdown_machine` to the calling process.
  """
  @spec shutdown_machine() :: :ok
  def shutdown_machine do
    send(self(), :shutdown_machine)
    :ok
  end

  @impl true
  @doc """
  Sends `{:tmux_cmd, args}` to the calling process and returns `{"", 0}`.
  """
  @spec tmux_cmd([String.t()]) :: {String.t(), non_neg_integer()}
  def tmux_cmd(args) do
    send(self(), {:tmux_cmd, args})
    {"", 0}
  end
end
