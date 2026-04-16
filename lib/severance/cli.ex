defmodule Severance.CLI do
  @moduledoc """
  Handles CLI argument parsing and the Overtime Protocol RPC connection.

  ## Usage

      sev                        # Start the daemon in the background
      sev start                  # Start the daemon in the background
      sev --daemon               # Run the daemon in the foreground (internal)
      sev init                   # Set up config, plist, and tmux
      sev update                 # Update to latest release
      sev version                # Print current version
      sev -v                     # Print current version
      sev status                 # Show daemon status and version info
      sev log                    # Print the activity log
      sev --shutdown-time HH:MM  # Start with custom shutdown time
      sev otp                    # Activate Overtime Protocol on running daemon
      sev overtime               # Activate Overtime Protocol on running daemon
      sev over_time_protocol     # Activate Overtime Protocol on running daemon
  """

  @doc """
  Parses command-line arguments into an action atom.

  Returns `:start` for no args, `start` subcommand, or unrecognized args.
  Returns `{:start, opts}` when options like `--shutdown-time` are provided.
  Returns `:daemon` or `{:daemon, opts}` for the internal `--daemon` flag.
  Returns `:overtime`, `:status`, `:init`, `:update`, or
  `:version` for their respective subcommands.

  ## Examples

      iex> Severance.CLI.parse_args([])
      :start

      iex> Severance.CLI.parse_args(["start"])
      :start

      iex> Severance.CLI.parse_args(["--daemon"])
      :daemon

      iex> Severance.CLI.parse_args(["otp"])
      :overtime

      iex> Severance.CLI.parse_args(["something-else"])
      :start
  """
  @type parse_args_result ::
          :start
          | {:start, keyword()}
          | :daemon
          | {:daemon, keyword()}
          | :overtime
          | :status
          | :log
          | :init
          | :update
          | :version
          | {:error, String.t()}

  @spec parse_args([String.t()]) :: parse_args_result()
  def parse_args(["init" | _rest]), do: :init
  def parse_args(["update" | _rest]), do: :update
  def parse_args(["version" | _rest]), do: :version
  def parse_args(["-v" | _rest]), do: :version
  def parse_args(["--version" | _rest]), do: :version
  def parse_args(["status" | _rest]), do: :status
  def parse_args(["log" | _rest]), do: :log
  def parse_args(["otp" | _rest]), do: :overtime
  def parse_args(["overtime" | _rest]), do: :overtime
  def parse_args(["over_time_protocol" | _rest]), do: :overtime
  def parse_args(["start"]), do: :start
  def parse_args(["start", "--shutdown-time" | _] = args), do: parse_args(tl(args))
  def parse_args(["start" | _rest]), do: :start

  def parse_args(["--daemon" | rest]) do
    case parse_args(rest) do
      :start -> :daemon
      {:start, opts} -> {:daemon, opts}
      other -> other
    end
  end

  def parse_args(["--shutdown-time", time_str | _rest]) do
    padded = if String.length(time_str) == 5, do: time_str <> ":00", else: time_str

    case Time.from_iso8601(padded) do
      {:ok, time} ->
        {:start, shutdown_time: time}

      {:error, _reason} ->
        {:error, "Invalid shutdown time: #{time_str}. Expected HH:MM format (e.g. 17:00)."}
    end
  end

  def parse_args(_args), do: :start

  @doc """
  Starts the daemon as a detached background process.

  Detects the binary path, spawns it with `--daemon`, and verifies
  the daemon is reachable. Accepts `binary:` option to override
  path detection (used in tests).

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec start_background(keyword(), keyword()) :: :ok | {:error, String.t()}
  def start_background(opts \\ [], spawn_opts \\ []) do
    binary = Keyword.get_lazy(spawn_opts, :binary, &Severance.Init.detect_binary_path/0)

    if File.exists?(binary) do
      cmd = build_daemon_cmd(binary, opts)
      System.cmd("/bin/sh", ["-c", cmd], stderr_to_stdout: true)
      await_daemon_ready()
    else
      {:error, "binary not found at #{binary}"}
    end
  end

  @readiness_interval_ms 500
  @readiness_max_attempts 20

  @doc """
  Polls `daemon_running?/0` until the daemon is reachable or attempts
  are exhausted. Cold Burrito starts need time to unpack, so a single
  check is unreliable.
  """
  @spec await_daemon_ready(non_neg_integer()) :: :ok | {:error, String.t()}
  def await_daemon_ready(attempts_left \\ @readiness_max_attempts)

  def await_daemon_ready(0) do
    {:error, "daemon did not start — check /tmp/severance.err for details"}
  end

  def await_daemon_ready(attempts_left) do
    Process.sleep(@readiness_interval_ms)

    if daemon_running?() do
      :ok
    else
      await_daemon_ready(attempts_left - 1)
    end
  end

  @doc """
  Builds the shell command to launch the daemon in the background.

  Quotes the binary path for safety. Redirects stdin/stdout/stderr
  and backgrounds the process with `&`.
  """
  @spec build_daemon_cmd(String.t(), keyword()) :: String.t()
  def build_daemon_cmd(binary_path, opts) do
    args = ["--daemon"]

    args =
      case Keyword.get(opts, :shutdown_time) do
        %Time{} = time ->
          args ++ ["--shutdown-time", Calendar.strftime(time, "%H:%M")]

        _ ->
          args
      end

    escaped_path = shell_escape(binary_path)
    arg_str = Enum.join(args, " ")
    "#{escaped_path} #{arg_str} </dev/null >>/tmp/severance.log 2>>/tmp/severance.err &"
  end

  @doc """
  Checks whether the severance daemon is currently running.

  Attempts to connect to the daemon node via distributed Erlang.
  Returns `true` if the connection succeeds, `false` otherwise.
  """
  @spec daemon_running?() :: boolean()
  def daemon_running? do
    case with_daemon_rpc(fn _target -> :ok end, quiet: true) do
      :ok -> true
      {:error, _} -> false
    end
  end

  @doc """
  Connects to the running severance node and activates the Overtime Protocol.

  Starts a temporary named node, connects to the daemon, makes an RPC call
  to `Severance.Countdown.overtime/0`, then returns the result.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec run_overtime() :: :ok | {:error, String.t()}
  def run_overtime do
    with_daemon_rpc(fn target ->
      case :rpc.call(target, Severance.Countdown, :overtime, []) do
        {:badrpc, reason} ->
          IO.puts("RPC failed: #{inspect(reason)}")
          {:error, "rpc failed"}

        _result ->
          IO.puts("Overtime Protocol activated. No shutdown today — but you'll hear about it.")
          :ok
      end
    end)
  end

  @doc false
  @spec run_stop() :: :ok | {:error, String.t()}
  def run_stop do
    with_daemon_rpc(fn target ->
      case :rpc.call(target, System, :stop, [0]) do
        {:badrpc, :nodedown} ->
          IO.puts("Severance daemon stopped.")
          :ok

        {:badrpc, reason} ->
          IO.puts("RPC failed: #{inspect(reason)}")
          {:error, "rpc failed"}

        _result ->
          IO.puts("Severance daemon stopped.")
          :ok
      end
    end)
  end

  @doc """
  Prints the activity log to stdout.

  If the log file doesn't exist, prints a message indicating no log was found.
  """
  @spec run_log(String.t()) :: :ok
  def run_log(log_file) do
    if File.exists?(log_file) do
      log_file |> File.read!() |> IO.write()
    else
      IO.puts("No activity log found at #{log_file}")
    end

    :ok
  end

  @doc """
  Connects to the running daemon and prints status information.

  Queries the daemon for countdown status and the latest version from GitHub.
  If the daemon is not running, prints a minimal status with the local version.

  Returns `:ok` always — status is informational.
  """
  @spec run_status() :: :ok
  def run_status do
    daemon_result = fetch_daemon_status()

    update_result =
      case daemon_result do
        {:ok, _} -> fetch_update_status()
        {:error, _} -> fetch_local_update_status()
      end

    IO.puts(format_status(daemon_result, update_result))
    :ok
  end

  @spec fetch_daemon_status() :: {:ok, map()} | {:error, term()}
  defp fetch_daemon_status do
    case with_daemon_rpc(&rpc_countdown_status/1, quiet: true) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  @spec rpc_countdown_status(atom()) :: {:ok, map()} | {:error, String.t()}
  defp rpc_countdown_status(target) do
    case :rpc.call(target, Severance.Countdown, :status, []) do
      {:badrpc, reason} ->
        {:error, inspect(reason)}

      status ->
        version =
          case :rpc.call(target, Severance.Updater, :current_version, []) do
            {:badrpc, _} -> Severance.Updater.current_version()
            v -> v
          end

        {:ok, Map.put(status, :version, version)}
    end
  end

  @spec fetch_update_status() :: {:ok, String.t()} | {:error, term()}
  defp fetch_update_status do
    with_daemon_rpc(&rpc_fetch_latest_version/1, quiet: true)
  end

  @spec fetch_local_update_status() :: {:ok, String.t()} | {:error, term()}
  defp fetch_local_update_status do
    Severance.Updater.fetch_latest_version()
  end

  @spec rpc_fetch_latest_version(atom()) :: {:ok, String.t()} | {:error, term()}
  defp rpc_fetch_latest_version(target) do
    case :rpc.call(target, Severance.Updater, :fetch_latest_version, []) do
      {:badrpc, reason} -> {:error, inspect(reason)}
      result -> result
    end
  end

  @doc """
  Formats status information into a human-readable string.

  Takes a daemon result (`{:ok, status_map}` or `{:error, reason}`) and
  an update result (`{:ok, latest_version}` or `{:error, reason}`).
  """
  @spec format_status(
          {:ok, map()} | {:error, term()},
          {:ok, String.t()} | {:error, term()}
        ) :: String.t()
  def format_status(daemon_result, update_result) do
    case daemon_result do
      {:ok, daemon} ->
        version = daemon.version
        header = "Severance v#{version}"
        overtime = if daemon.mode == :overtime, do: "active", else: "inactive"

        shutdown =
          if daemon.minutes_remaining <= 0 do
            "#{format_time(daemon.shutdown_time)} (passed)"
          else
            "#{format_time(daemon.shutdown_time)} (#{daemon.minutes_remaining}m remaining)"
          end

        update = format_update(update_result, version)

        """
        #{header}
        Status:     running
        Overtime:   #{overtime}
        Shutdown:   #{shutdown}
        Update:     #{update}\
        """

      {:error, _reason} ->
        version = Severance.Updater.current_version()
        header = "Severance v#{version}"
        update = format_update(update_result, version)

        """
        #{header}
        Status:     not running
        Update:     #{update}\
        """
    end
  end

  @spec format_time(Time.t()) :: String.t()
  defp format_time(time) do
    Calendar.strftime(time, "%H:%M")
  end

  @spec format_update({:ok, String.t()} | {:error, term()}, String.t()) :: String.t()
  defp format_update({:ok, latest}, current) do
    case Severance.Updater.check_version(current, latest) do
      :update_available -> "v#{latest} available (run `sev update`)"
      :up_to_date -> "up to date"
    end
  end

  defp format_update({:error, _reason}, _current) do
    "unknown (check failed)"
  end

  @spec with_daemon_rpc((atom() -> term()), keyword()) :: term() | {:error, String.t()}
  defp with_daemon_rpc(callback, opts \\ []) do
    quiet = Keyword.get(opts, :quiet, false)
    hostname = node_hostname()
    target = :"severance@#{hostname}"
    cli_name = :"severance_cli_#{:rand.uniform(100_000)}@#{hostname}"

    prev_level = Map.get(:logger.get_primary_config(), :level, :all)
    if quiet, do: :logger.set_primary_config(:level, :error)

    result = start_and_connect(cli_name, target, callback, quiet)

    if quiet, do: :logger.set_primary_config(:level, prev_level)
    result
  end

  @spec start_and_connect(atom(), atom(), (atom() -> term()), boolean()) ::
          term() | {:error, String.t()}
  defp start_and_connect(cli_name, target, callback, quiet) do
    case Node.start(cli_name, name_domain: :shortnames) do
      {:ok, _pid} ->
        Node.set_cookie(Node.self(), cookie())
        connect_to_daemon(target, callback, quiet)

      {:error, {:already_started, _pid}} ->
        handle_already_started(target, callback, quiet)

      {:error, reason} ->
        if !quiet, do: IO.puts("Could not start distribution: #{inspect(reason)}")
        {:error, "distribution failed"}
    end
  end

  @spec handle_already_started(atom(), (atom() -> term()), boolean()) ::
          term() | {:error, String.t()}
  defp handle_already_started(target, callback, quiet) do
    if Node.self() == target do
      if !quiet, do: IO.puts("Cannot check daemon: this node is the daemon node.")
      {:error, "self-connection"}
    else
      connect_to_daemon(target, callback, quiet)
    end
  end

  @spec connect_to_daemon(atom(), (atom() -> term()), boolean()) ::
          term() | {:error, String.t()}
  defp connect_to_daemon(target, callback, quiet) do
    if Node.connect(target) do
      callback.(target)
    else
      if !quiet, do: print_connection_failure()
      {:error, "connection failed"}
    end
  end

  @spec print_connection_failure() :: :ok
  defp print_connection_failure do
    IO.puts("Could not connect to severance daemon.")

    case :erl_epmd.names() do
      {:ok, []} ->
        IO.puts("EPMD reports no registered nodes.")

      {:ok, names} ->
        IO.puts("EPMD registered nodes: #{format_epmd_names(names)}")

      {:error, _} ->
        IO.puts("EPMD is not running.")
    end
  end

  @spec format_epmd_names([{charlist(), non_neg_integer()}]) :: String.t()
  defp format_epmd_names(names) do
    Enum.map_join(names, ", ", fn {name, port} -> "#{name}:#{port}" end)
  end

  @spec node_hostname() :: String.t()
  defp node_hostname, do: "localhost"

  @spec cookie() :: atom()
  defp cookie do
    Node.get_cookie()
  end

  @spec shell_escape(String.t()) :: String.t()
  defp shell_escape(path) do
    escaped = String.replace(path, "'", "'\\''")
    "'#{escaped}'"
  end
end
