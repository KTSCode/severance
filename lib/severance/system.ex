defmodule Severance.System do
  @moduledoc """
  Behaviour defining system interaction callbacks.

  Implementations handle macOS notifications, tmux commands, and
  machine shutdown. The active adapter is configured via
  `:severance, :system_adapter`.
  """

  @callback notify(title :: String.t(), message :: String.t(), sound :: String.t()) :: :ok
  @callback shutdown_machine() :: :ok
  @callback tmux_cmd(args :: [String.t()]) :: {String.t(), non_neg_integer()}

  @doc """
  Returns the configured system adapter module.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:severance, :system_adapter, Severance.System.Real)
  end
end
