defmodule Severance.Application do
  @moduledoc """
  OTP Application entry point. Dispatches CLI commands or starts the
  supervision tree with the Countdown GenServer.

  When running as a Burrito binary, CLI arguments are read via
  `Burrito.Util.Args.argv/0`. In dev/test, falls back to `System.argv/0`.
  """

  use Application

  alias Severance.CLI
  alias Severance.Config

  require Logger

  @impl true
  def start(_type, _args) do
    args = cli_argv()

    case CLI.parse_args(args) do
      :init ->
        Severance.Init.run()
        System.halt(0)

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
  Resolves the effective configuration by layering sources in priority order:

  1. Compiled defaults from `config/config.exs` (lowest)
  2. User config file at `~/.config/severance/config.exs`
  3. `SEVERANCE_SHUTDOWN_TIME` environment variable
  4. CLI `--shutdown-time` flag (highest)

  Stores `overtime_notifications` in Application env as a side effect.
  Accepts `config_dir:` option for testability.
  """
  @spec resolve_config(keyword(), keyword()) :: %{
          shutdown_time: Time.t(),
          overtime_notifications: boolean()
        }
  def resolve_config(opts \\ [], resolve_opts \\ []) do
    config_dir = Keyword.get(resolve_opts, :config_dir)

    # Layer 1: compiled defaults
    compiled_time = Application.get_env(:severance, :shutdown_time, ~T[17:00:00])
    overtime_notifications = Application.get_env(:severance, :overtime_notifications, true)

    # Layer 2: user config file
    file_result =
      if config_dir do
        Config.read(config_dir)
      else
        Config.read()
      end

    {shutdown_time, overtime_notifications} =
      case file_result do
        {:ok, file_config} ->
          time = parse_time_string(file_config.shutdown_time, compiled_time)
          {time, Map.get(file_config, :overtime_notifications, overtime_notifications)}

        {:error, :not_found} ->
          unless resolve_opts[:suppress_warning] do
            Logger.info("No config file found. Run `sev init` to create one.")
          end

          {compiled_time, overtime_notifications}
      end

    # Layer 3: env var
    shutdown_time =
      case System.get_env("SEVERANCE_SHUTDOWN_TIME") do
        nil -> shutdown_time
        time_str -> parse_time_string(time_str, shutdown_time)
      end

    # Layer 4: CLI opts
    shutdown_time = Keyword.get(opts, :shutdown_time, shutdown_time)

    # Side effect: store overtime_notifications for Countdown to read
    Application.put_env(:severance, :overtime_notifications, overtime_notifications)

    %{shutdown_time: shutdown_time, overtime_notifications: overtime_notifications}
  end

  @doc """
  Starts the daemon supervision tree.
  """
  @spec start_daemon(keyword()) :: {:ok, pid()}
  def start_daemon(opts \\ []) do
    config = resolve_config(opts)
    start_children = Application.get_env(:severance, :start_children, true)

    children =
      if start_children do
        [{Severance.Countdown, shutdown_time: config.shutdown_time}]
      else
        []
      end

    sup_opts = [strategy: :one_for_one, name: Severance.Supervisor]
    Supervisor.start_link(children, sup_opts)
  end

  defp parse_time_string(time_str, fallback) do
    padded = if String.length(time_str) == 5, do: time_str <> ":00", else: time_str

    case Time.from_iso8601(padded) do
      {:ok, time} -> time
      {:error, _} -> fallback
    end
  end
end
