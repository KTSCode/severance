defmodule Severance.Application do
  @moduledoc """
  OTP Application entry point. Dispatches CLI commands or starts the
  supervision tree with the Countdown GenServer.

  When running as a Burrito binary, CLI arguments are read via
  `Burrito.Util.Args.argv/0`. In dev/test, falls back to `System.argv/0`.
  """

  use Application

  alias Severance.CLI

  @impl true
  def start(_type, _args) do
    args = cli_argv()

    case CLI.parse_args(args) do
      :overtime ->
        result = CLI.run_overtime()
        System.halt(if result == :ok, do: 0, else: 1)

      :stop ->
        result = CLI.run_stop()
        System.halt(if result == :ok, do: 0, else: 1)

      :start ->
        start_daemon()

      {:start, opts} ->
        start_daemon(opts)
    end
  end

  @doc """
  Returns CLI arguments from Burrito when available, otherwise `System.argv/0`.
  """
  @burrito_args Burrito.Util.Args

  @spec cli_argv() :: [String.t()]
  def cli_argv do
    if Code.ensure_loaded?(@burrito_args) do
      @burrito_args.argv()
    else
      System.argv()
    end
  end

  @doc """
  Starts the daemon supervision tree.
  """
  @spec start_daemon(keyword()) :: {:ok, pid()}
  def start_daemon(opts \\ []) do
    shutdown_time =
      Keyword.get(opts, :shutdown_time) ||
        Application.get_env(:severance, :shutdown_time, ~T[17:00:00])

    start_children = Application.get_env(:severance, :start_children, true)

    children =
      if start_children do
        [{Severance.Countdown, shutdown_time: shutdown_time}]
      else
        []
      end

    sup_opts = [strategy: :one_for_one, name: Severance.Supervisor]
    Supervisor.start_link(children, sup_opts)
  end
end
