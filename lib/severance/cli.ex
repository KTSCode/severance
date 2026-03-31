defmodule Severance.CLI do
  @moduledoc """
  Handles CLI argument parsing and the Overtime Protocol RPC connection.

  ## Usage

      sev                        # Start the daemon
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

  Returns `:start` for no args or unrecognized args, `{:start, opts}` when
  options are provided, `:overtime` when the `otp` subcommand is given,
  `:stop` when the `stop` subcommand is given, or `:update` when the
  `update` subcommand is given.

  ## Examples

      iex> Severance.CLI.parse_args([])
      :start

      iex> Severance.CLI.parse_args(["otp"])
      :overtime

      iex> Severance.CLI.parse_args(["something-else"])
      :start
  """
  @type parse_args_result ::
          :start
          | {:start, keyword()}
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
  Checks whether the severance daemon is currently running.

  Attempts to connect to the daemon node via distributed Erlang.
  Returns `true` if the connection succeeds, `false` otherwise.
  """
  @spec daemon_running?() :: boolean()
  def daemon_running? do
    case with_daemon_rpc(fn _target -> :ok end) do
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
      :rpc.call(target, Severance.Countdown, :overtime, [])
      IO.puts("Overtime Protocol activated. No shutdown today — but you'll hear about it.")
      :ok
    end)
  end

  @doc """
  Connects to the running severance node and stops it.

  Starts a temporary named node, connects to the daemon, makes an RPC call
  to `System.stop/1`, then returns the result.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec run_stop() :: :ok | {:error, String.t()}
  def run_stop do
    with_daemon_rpc(fn target ->
      :rpc.call(target, System, :stop, [0])
      IO.puts("Severance daemon stopped.")
      :ok
    end)
  end

  @spec with_daemon_rpc((atom() -> term())) :: term() | {:error, String.t()}
  defp with_daemon_rpc(callback) do
    hostname = node_hostname()
    target = :"severance@#{hostname}"
    cli_name = :"severance_cli_#{:rand.uniform(100_000)}@#{hostname}"

    case Node.start(cli_name, name_domain: :shortnames) do
      {:ok, _pid} ->
        Node.set_cookie(Node.self(), cookie())

        case Node.connect(target) do
          true ->
            callback.(target)

          false ->
            IO.puts("Could not connect to severance daemon. Is it running?")
            {:error, "connection failed"}
        end

      {:error, reason} ->
        IO.puts("Could not start distribution: #{inspect(reason)}")
        {:error, "distribution failed"}
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
end
