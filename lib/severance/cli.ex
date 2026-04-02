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
      sev --shutdown-time HH:MM  # Start with custom shutdown time
      sev otp                    # Activate Overtime Protocol on running daemon
      sev overtime               # Activate Overtime Protocol on running daemon
      sev over_time_protocol     # Activate Overtime Protocol on running daemon
      sev stop                   # Stop the running daemon
  """

  @doc """
  Parses command-line arguments into an action atom.

  Returns `:start` for no args, `start` subcommand, or unrecognized args.
  Returns `{:start, opts}` when options like `--shutdown-time` are provided.
  Returns `:daemon` or `{:daemon, opts}` for the internal `--daemon` flag.
  Returns `:overtime`, `:stop`, `:init`, `:update`, or `:version` for
  their respective subcommands.

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
          | :stop
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
  def parse_args(["otp" | _rest]), do: :overtime
  def parse_args(["overtime" | _rest]), do: :overtime
  def parse_args(["over_time_protocol" | _rest]), do: :overtime
  def parse_args(["stop" | _rest]), do: :stop
  def parse_args(["start" | rest]), do: parse_args(rest)

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

  @doc """
  Connects to the running severance node and stops it.

  Starts a temporary named node, connects to the daemon, makes an RPC call
  to `System.stop/1`, then returns the result.

  Returns `:ok` on success, `{:error, reason}` on failure.
  Treats `{:badrpc, :nodedown}` as success since the remote node shut
  down before responding.
  """
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

  @spec with_daemon_rpc((atom() -> term()), keyword()) :: term() | {:error, String.t()}
  defp with_daemon_rpc(callback, opts \\ []) do
    quiet = Keyword.get(opts, :quiet, false)
    hostname = node_hostname()
    target = :"severance@#{hostname}"
    cli_name = :"severance_cli_#{:rand.uniform(100_000)}@#{hostname}"

    prev_level = :logger.get_primary_config() |> Map.get(:level, :all)
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
        unless quiet, do: IO.puts("Could not start distribution: #{inspect(reason)}")
        {:error, "distribution failed"}
    end
  end

  @spec handle_already_started(atom(), (atom() -> term()), boolean()) ::
          term() | {:error, String.t()}
  defp handle_already_started(target, callback, quiet) do
    if Node.self() == target do
      unless quiet, do: IO.puts("Cannot check daemon: this node is the daemon node.")
      {:error, "self-connection"}
    else
      connect_to_daemon(target, callback, quiet)
    end
  end

  @spec connect_to_daemon(atom(), (atom() -> term()), boolean()) ::
          term() | {:error, String.t()}
  defp connect_to_daemon(target, callback, quiet) do
    case Node.connect(target) do
      true ->
        callback.(target)

      false ->
        unless quiet, do: IO.puts("Could not connect to severance daemon. Is it running?")
        {:error, "connection failed"}
    end
  end

  @spec node_hostname() :: String.t()
  defp node_hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

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
