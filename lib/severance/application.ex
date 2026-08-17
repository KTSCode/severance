defmodule Severance.Application do
  @moduledoc """
  OTP Application entry point. Dispatches CLI commands or starts the
  supervision tree with the Countdown GenServer.

  When running as a Burrito binary, CLI arguments are read via
  `Burrito.Util.Args.argv/0`. In dev/test, falls back to `System.argv/0`.
  """

  use Application

  alias Severance.ActivityLog
  alias Severance.CLI
  alias Severance.Config
  alias Severance.Countdown
  alias Severance.StatusPublisher

  require Logger

  @impl true
  def start(_type, _args) do
    if burrito?() do
      cli_argv() |> CLI.parse_args() |> dispatch()
    else
      start_daemon()
    end
  end

  @spec dispatch(CLI.parse_args_result()) :: {:ok, pid()} | no_return()
  defp dispatch({:help, :agent}) do
    IO.puts(CLI.agent_usage())
    System.halt(0)
  end

  defp dispatch({:help, path}) do
    IO.puts(CLI.usage(path))
    System.halt(0)
  end

  defp dispatch({:error, message}) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  defp dispatch(%{path: [:version]}) do
    IO.puts(Severance.Updater.current_version())
    System.halt(0)
  end

  defp dispatch(%{path: [sub]}) when sub in [:update, :upgrade] do
    result = Severance.Updater.run()
    System.halt(if result == :ok, do: 0, else: 1)
  end

  defp dispatch(%{path: [:log]}) do
    config = resolve_config([], suppress_warning: true)
    CLI.run_log(config.log_file)
    System.halt(0)
  end

  defp dispatch(%{path: [sub]}) when sub in [:otp, :overtime, :over_time_protocol] do
    result = CLI.run_overtime()
    System.halt(if result == :ok, do: 0, else: 1)
  end

  defp dispatch(%{path: [:reload]}) do
    result = CLI.run_reload()
    System.halt(if result == :ok, do: 0, else: 1)
  end

  defp dispatch(%{path: [:init], options: opts}) do
    resolve_config([], suppress_warning: true)
    Severance.Init.run(%{with_tmux?: opts.with_tmux})
    System.halt(0)
  end

  defp dispatch(%{path: [:status], options: opts, arguments: args}) do
    Node.stop()
    resolve_config([], suppress_warning: true)

    # The publisher name is a positional CLI arg matched against user-authored
    # config (loaded via Code.eval_file/1), so converting it to an atom is
    # trusted input — the same trust model as the rest of the config pipeline.
    publisher_name =
      case Map.get(args, :publisher) do
        nil -> nil
        name -> String.to_atom(name)
      end

    CLI.run_status(%{publisher_name: publisher_name, teardown?: opts.teardown})
    System.halt(0)
  end

  defp dispatch(%{path: [:start], options: opts}) do
    kw = start_keyword(opts)

    # --daemon runs the supervision tree in this (foreground) process. Without it,
    # a packaged Burrito binary spawns a detached background daemon, while dev/test
    # starts the tree inline.
    cond do
      opts.daemon -> start_daemon(kw)
      burrito?() -> start_or_notify(kw)
      true -> start_daemon(kw)
    end
  end

  @spec start_keyword(map()) :: keyword()
  defp start_keyword(opts) do
    case Map.get(opts, :shutdown_time) do
      nil -> []
      time -> [shutdown_time: time]
    end
  end

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
          overtime_notifications: boolean(),
          log_file: String.t()
        }
  def resolve_config(opts \\ [], resolve_opts \\ []) do
    config_dir = Keyword.get(resolve_opts, :config_dir)

    # Layer 1: compiled defaults
    compiled_time = Application.get_env(:severance, :shutdown_time, ~T[17:00:00])
    overtime_notifications = Application.get_env(:severance, :overtime_notifications, true)
    compiled_log_file = Application.get_env(:severance, :log_file, ActivityLog.default_log_file())

    # Layer 2: user config file
    file_result =
      if config_dir do
        Config.read(config_dir)
      else
        Config.read()
      end

    {shutdown_time, overtime_notifications, log_file} =
      case file_result do
        {:ok, file_config} ->
          time = parse_time_string(file_config.shutdown_time, compiled_time)
          ot = Map.get(file_config, :overtime_notifications, overtime_notifications)
          lf = Map.get(file_config, :log_file, compiled_log_file)
          Application.put_env(:severance, :publishers, Map.get(file_config, :publishers, %{}))
          {time, ot, Path.expand(lf)}

        {:error, :not_found} ->
          if !resolve_opts[:suppress_warning] do
            Logger.info("No config file found. Run `sev init` to create one.")
          end

          {compiled_time, overtime_notifications, Path.expand(compiled_log_file)}
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
    Application.put_env(:severance, :log_file, log_file)

    %{shutdown_time: shutdown_time, overtime_notifications: overtime_notifications, log_file: log_file}
  end

  @doc """
  Starts the daemon supervision tree.

  Ensures BEAM distribution is active so the daemon registers with EPMD
  as `severance@hostname`. This is required because Burrito's Zig launcher
  bypasses `env.sh` and never sets `RELEASE_DISTRIBUTION` or `RELEASE_NODE`.
  """
  @spec start_daemon(keyword()) :: {:ok, pid()}
  def start_daemon(opts \\ []) do
    if Application.get_env(:severance, :start_distribution, true) do
      ensure_distribution()
    end

    Application.put_env(:severance, :launch_opts, opts)
    config = resolve_config(opts)
    start_children = Application.get_env(:severance, :start_children, true)

    children =
      if start_children do
        [
          {Countdown, shutdown_time: config.shutdown_time},
          Severance.StatusPublisher.Supervisor
        ]
      else
        []
      end

    sup_opts = [strategy: :one_for_one, name: Severance.Supervisor]
    result = Supervisor.start_link(children, sup_opts)

    with {:ok, _pid} <- result, true <- start_children do
      log_file = Application.get_env(:severance, :log_file, ActivityLog.default_log_file())
      ActivityLog.log_started(log_file)
    end

    result
  end

  @doc """
  Reloads the running daemon's configuration in place, without a restart.

  Re-resolves config from the same sources as `start_daemon/1` (file, env
  var, launch flag), re-arms `Countdown` with the resolved `shutdown_time`
  while preserving `mode`, and rebuilds the publisher worker set. Does not
  touch the `:retry_shutdown` or `:overtime_burst` chains, so an
  in-progress shutdown or overtime opt-out cannot be escaped by reloading.

  `resolve_opts` passes through to `resolve_config/2` (e.g. `config_dir:`
  for tests); defaults to suppressing the "no config file" log.
  """
  @spec reload(keyword()) :: {:ok, map()}
  def reload(resolve_opts \\ []) do
    launch_opts = Application.get_env(:severance, :launch_opts, [])
    config = resolve_config(launch_opts, Keyword.put_new(resolve_opts, :suppress_warning, true))

    Countdown.reload(config.shutdown_time)

    publishers =
      case StatusPublisher.Supervisor.reload() do
        {:ok, count} -> count
        {:error, :not_running} -> 0
      end

    {:ok,
     %{
       shutdown_time: config.shutdown_time,
       publishers: publishers,
       pinned_shutdown_time?: Keyword.has_key?(launch_opts, :shutdown_time)
     }}
  end

  @doc """
  Returns the node name the daemon uses for BEAM distribution.
  """
  @spec daemon_node_name() :: node()
  def daemon_node_name do
    :"severance@#{daemon_hostname()}"
  end

  @spec ensure_distribution() :: :ok
  defp ensure_distribution do
    ensure_epmd()
    node_name = daemon_node_name()

    case Node.start(node_name, name_domain: :shortnames) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "Failed to start BEAM distribution: #{inspect(reason)}. " <>
                "The daemon would be unreachable by sev overtime."
    end
  end

  @spec ensure_epmd() :: :ok
  defp ensure_epmd do
    case :erl_epmd.names() do
      {:ok, _names} ->
        :ok

      {:error, _} ->
        case find_epmd() do
          nil ->
            raise "Could not locate epmd. " <>
                    "The daemon would be unreachable by sev overtime."

          path ->
            System.cmd(path, ["-daemon"])
        end

        :ok
    end
  end

  @spec find_epmd() :: String.t() | nil
  defp find_epmd do
    case :os.find_executable(~c"epmd") do
      false ->
        path = Path.join(erts_bin_dir(), "epmd")
        if File.exists?(path), do: path

      path ->
        List.to_string(path)
    end
  end

  @spec erts_bin_dir() :: String.t()
  defp erts_bin_dir do
    System.get_env("BINDIR") ||
      Path.join([
        List.to_string(:code.root_dir()),
        "erts-#{:version |> :erlang.system_info() |> List.to_string()}",
        "bin"
      ])
  end

  @spec daemon_hostname() :: String.t()
  defp daemon_hostname, do: "localhost"

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
