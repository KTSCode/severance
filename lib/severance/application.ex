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
    cli_argv() |> CLI.parse_args() |> dispatch()
  end

  @spec dispatch(CLI.parse_args_result()) :: {:ok, pid()}
  defp dispatch(:init) do
    Severance.Init.run()
    System.halt(0)
  end

  defp dispatch(:update) do
    result = Severance.Updater.run()
    System.halt(if result == :ok, do: 0, else: 1)
  end

  defp dispatch(:version) do
    IO.puts(Severance.Updater.current_version())
    System.halt(0)
  end

  defp dispatch(:overtime) do
    result = CLI.run_overtime()
    System.halt(if result == :ok, do: 0, else: 1)
  end

  defp dispatch(:status) do
    Node.stop()
    CLI.run_status()
    System.halt(0)
  end

  defp dispatch(:stop) do
    result = CLI.run_stop()
    System.halt(if result == :ok, do: 0, else: 1)
  end

  defp dispatch({:error, message}) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  defp dispatch(:start) do
    if burrito?(), do: start_or_notify([]), else: start_daemon()
  end

  defp dispatch({:start, opts}) do
    if burrito?(), do: start_or_notify(opts), else: start_daemon(opts)
  end

  defp dispatch(:daemon), do: start_daemon()
  defp dispatch({:daemon, opts}), do: start_daemon(opts)

  @spec start_or_notify(keyword()) :: no_return()
  defp start_or_notify(opts) do
    # The release boots as severance@hostname. Stop distribution so
    # the background daemon can claim that node name, and so the
    # readiness check doesn't self-connect.
    Node.stop()

    if CLI.daemon_running?() do
      IO.puts("Severance daemon is already running.")
      System.halt(0)
    else
      case CLI.start_background(opts) do
        :ok ->
          IO.puts("Severance daemon started.")
          System.halt(0)

        {:error, reason} ->
          IO.puts(:stderr, "Failed to start daemon: #{reason}")
          System.halt(1)
      end
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
    Severance.Updater.create_cache_table()

    children =
      if start_children do
        [{Severance.Countdown, shutdown_time: config.shutdown_time}]
      else
        []
      end

    sup_opts = [strategy: :one_for_one, name: Severance.Supervisor]
    Supervisor.start_link(children, sup_opts)
  end

  @spec burrito?() :: boolean()
  defp burrito? do
    Code.ensure_loaded?(@burrito_args) and
      @burrito_args.get_bin_path() != :not_in_burrito
  end

  defp parse_time_string(time_str, fallback) do
    padded = if String.length(time_str) == 5, do: time_str <> ":00", else: time_str

    case Time.from_iso8601(padded) do
      {:ok, time} -> time
      {:error, _} -> fallback
    end
  end
end
