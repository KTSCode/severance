defmodule Severance.CLI do
  @moduledoc """
  Handles CLI argument parsing and the Overtime Protocol RPC connection.

  Parsing is delegated to [CliMate](https://hexdocs.pm/cli_mate). The command
  tree lives in the `@command` module attribute.

  ## Usage

      sev                              # Start the daemon in the background
      sev start                        # Start the daemon in the background
      sev --daemon                     # Run the daemon in the foreground (internal)
      sev init [--with-tmux]           # Set up config, plist, and tmux
      sev update                       # Update to latest release
      sev version                      # Print current version
      sev -v                           # Print current version
      sev status                       # Show daemon status and version info
      sev status <publisher>           # Invoke a publisher once for debugging
      sev status <publisher> --teardown # Run a publisher's teardown
      sev log                          # Print the activity log
      sev --shutdown-time HH:MM        # Start with custom shutdown time
      sev otp                          # Activate Overtime Protocol on running daemon
      sev overtime                     # Activate Overtime Protocol on running daemon
      sev over_time_protocol           # Activate Overtime Protocol on running daemon
  """

  alias CliMate.CLI, as: Mate
  alias Severance.StatusPublisher.Tmux.ConfScanner

  @subcommand_names ~w(start init update version status log otp overtime over_time_protocol)

  @command [
    name: "sev",
    options: [
      daemon: [type: :boolean, default: false, doc: "Run daemon in foreground (internal)"],
      shutdown_time: [
        type: :string,
        cast: &__MODULE__.cast_shutdown_time/1,
        doc: "Override shutdown time (HH:MM)"
      ]
    ],
    subcommands: [
      start: [options: []],
      init: [options: [with_tmux: [type: :boolean, default: false, doc: "Seed tmux publisher"]]],
      update: [options: []],
      version: [options: []],
      status: [
        options: [teardown: [type: :boolean, default: false, doc: "Tear down publisher"]],
        arguments: [publisher: [required: false]]
      ],
      log: [options: []],
      otp: [options: []],
      overtime: [options: []],
      over_time_protocol: [options: []]
    ]
  ]

  @type parse_args_result ::
          :start
          | {:start, keyword()}
          | :daemon
          | {:daemon, keyword()}
          | :overtime
          | {:status, map()}
          | :log
          | {:init, map()}
          | :update
          | :version
          | :help
          | {:error, String.t()}

  @doc """
  Parses command-line arguments into an action.

  Returns `:start` for no args or the `start` subcommand.
  Returns `{:start, opts}` when options like `--shutdown-time` are provided.
  Returns `:daemon` or `{:daemon, opts}` for the internal `--daemon` flag.
  Returns `:overtime`, `{:status, opts}`, `{:init, opts}`, `:log`,
  `:update`, or `:version` for their respective subcommands.
  Returns `{:error, message}` for unrecognized commands or invalid options.

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
      {:error, "Unknown command: something-else"}
  """
  @spec parse_args([String.t()]) :: parse_args_result()
  def parse_args(argv) do
    argv |> normalize_argv() |> Mate.parse(@command) |> to_result()
  end

  @doc """
  Returns the CliMate-generated usage block for the `sev` command.
  """
  @spec usage() :: String.t()
  def usage do
    @command
    |> Mate.format_usage(ansi_enabled: false)
    |> IO.iodata_to_binary()
  end

  @doc false
  @spec cast_shutdown_time(String.t()) :: {:ok, Time.t()} | {:error, String.t()}
  def cast_shutdown_time(time_str) do
    padded = if String.length(time_str) == 5, do: time_str <> ":00", else: time_str

    case Time.from_iso8601(padded) do
      {:ok, time} ->
        {:ok, time}

      {:error, _reason} ->
        {:error, "Invalid shutdown time: #{time_str}. Expected HH:MM format (e.g. 17:00)."}
    end
  end

  defp normalize_argv(argv) do
    cond do
      "--version" in argv or "-v" in argv -> ["version"]
      Enum.any?(argv, &(&1 in @subcommand_names)) -> argv
      true -> ["start" | argv]
    end
  end

  defp to_result({:ok, %{options: %{help: true}}}), do: :help

  defp to_result({:ok, %{path: [:version]}}), do: :version
  defp to_result({:ok, %{path: [:update]}}), do: :update
  defp to_result({:ok, %{path: [:log]}}), do: :log

  defp to_result({:ok, %{path: [sub]}}) when sub in [:otp, :overtime, :over_time_protocol] do
    :overtime
  end

  defp to_result({:ok, %{path: [:init], options: opts}}) do
    {:init, %{with_tmux?: Map.get(opts, :with_tmux, false)}}
  end

  defp to_result({:ok, %{path: [:status], options: opts, arguments: args}}) do
    {:status,
     %{
       publisher_name: publisher_atom(Map.get(args, :publisher)),
       teardown?: Map.get(opts, :teardown, false)
     }}
  end

  defp to_result({:ok, %{path: [:start], options: opts}}) do
    keyword =
      case Map.get(opts, :shutdown_time) do
        nil -> []
        time -> [shutdown_time: time]
      end

    case {Map.get(opts, :daemon, false), keyword} do
      {true, []} -> :daemon
      {true, kw} -> {:daemon, kw}
      {false, []} -> :start
      {false, kw} -> {:start, kw}
    end
  end

  defp to_result({:error, reason}), do: {:error, format_error(reason)}

  defp publisher_atom(nil), do: nil
  defp publisher_atom(str) when is_binary(str), do: String.to_atom(str)

  defp format_error({:unknown_subcommand, sub}), do: "Unknown command: #{sub}"
  defp format_error({:extra_argument, v}), do: "Unknown command: #{v}"
  defp format_error({:option_cast, _key, msg}) when is_binary(msg), do: msg
  defp format_error({:option_cast, key, reason}), do: "Invalid #{key}: #{inspect(reason)}"
  defp format_error({:invalid, [{flag, _} | _]}), do: "Invalid option: #{flag}"
  defp format_error({:argument_type, key, type}), do: "Invalid #{key}: expected #{type}"
  defp format_error({:missing_argument, key}), do: "Missing argument: #{key}"
  defp format_error(:missing_subcommand), do: "Missing subcommand"
  defp format_error(other), do: inspect(other)

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
    log_dir = Path.join(System.user_home!(), "Library/Logs")
    {:error, "daemon did not start — check #{log_dir}/severance.err for details"}
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
    log_dir = Path.join(System.user_home!(), "Library/Logs")
    "#{escaped_path} #{arg_str} </dev/null >>#{log_dir}/severance.log 2>>#{log_dir}/severance.err &"
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

  Accepts an optional opts map with `:publisher_name` (atom | nil) and
  `:teardown?` (boolean). When a publisher name is given, invokes that
  publisher once for debugging. Plain invocation prints the normal status
  block plus optional tmux wiring and publisher error blocks.

  `allow_nonexistent_atoms: true` is passed to `OptionParser` when parsing
  `status` flags so arbitrary user-defined publisher names are accepted as
  atoms. These atoms come from user config evaluated with `Code.eval_file/1`
  (same trust model as the rest of the config pipeline).

  Returns `:ok` always — status is informational.
  """
  @spec run_status(map()) :: :ok
  def run_status(opts \\ %{}) do
    case opts do
      %{publisher_name: name, teardown?: true} when not is_nil(name) ->
        run_publisher_debug(name, :teardown)

      %{publisher_name: name} when not is_nil(name) ->
        run_publisher_debug(name, :publish)

      %{teardown?: true} ->
        IO.puts(:stderr, "--teardown requires --<publisher-name>")
        :ok

      _ ->
        print_normal_status()
    end
  end

  defp print_normal_status do
    daemon_result = fetch_daemon_status()

    update_result =
      case daemon_result do
        {:ok, _} -> fetch_update_status()
        {:error, _} -> fetch_local_update_status()
      end

    IO.puts(format_status(daemon_result, update_result))
    print_tmux_wiring_block()
    print_publisher_errors_block(daemon_result)
    :ok
  end

  defp run_publisher_debug(name, action) do
    publishers = local_publishers()

    case Map.fetch(publishers, name) do
      :error ->
        IO.puts(:stderr, "unknown publisher #{name}")
        :ok

      {:ok, spec} when action == :teardown ->
        case Map.get(spec, :teardown) do
          nil ->
            IO.puts("publisher #{name} has no teardown")

          fun when is_function(fun, 0) ->
            report_debug_result(name, :teardown, safe_call(fun, []))
        end

        :ok

      {:ok, %{fn: fun}} ->
        report_debug_result(name, :publish, safe_call(fun, [rpc_status_or_local()]))
        :ok
    end
  end

  @publisher_debug_timeout 2_000

  defp safe_call(fun, args) do
    parent = self()
    ref = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        send(parent, {ref, apply(fun, args)})
      end)

    receive do
      {^ref, _value} ->
        Process.demonitor(mref, [:flush])
        :ok

      {:DOWN, ^mref, :process, ^pid, reason} ->
        {:error, {:crash, reason}}
    after
      @publisher_debug_timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(mref, [:flush])
        {:error, :timeout}
    end
  end

  defp report_debug_result(_name, _phase, :ok), do: :ok

  defp report_debug_result(name, phase, {:error, reason}) do
    IO.puts(:stderr, "publisher #{name} #{phase} failed: #{inspect(reason)}")
  end

  defp local_publishers do
    Application.get_env(:severance, :publishers, %{})
  end

  defp rpc_status_or_local do
    case fetch_daemon_status() do
      {:ok, status} -> status
      _ -> %Severance.Status{mode: :severance, phase: :waiting}
    end
  end

  defp print_tmux_wiring_block do
    vars =
      Enum.flat_map(local_publishers(), fn {_, spec} -> List.wrap(spec[:tmux_var]) end)

    if vars != [] do
      contents = ConfScanner.read_tmux_conf()

      missing =
        Enum.reject(vars, &ConfScanner.references?(contents, &1))

      case missing do
        [] ->
          :ok

        vars ->
          IO.puts("\ntmux:")
          Enum.each(vars, &IO.puts("  @sev_#{&1} NOT in ~/.tmux.conf"))
      end
    end
  end

  defp print_publisher_errors_block({:error, _}), do: :ok

  defp print_publisher_errors_block({:ok, _}) do
    names = Map.keys(local_publishers())

    rows =
      Enum.flat_map(names, fn name ->
        case rpc_worker_errors(name) do
          [] -> []
          [{phase, reason, at} | _] -> [{name, phase, reason, at}]
        end
      end)

    case rows do
      [] ->
        :ok

      rows ->
        IO.puts("\npublisher errors (current config):")

        Enum.each(rows, fn {name, phase, reason, at} ->
          IO.puts("  #{name}: #{phase} #{inspect(reason)} (last at #{Calendar.strftime(at, "%H:%M:%S")})")
        end)
    end
  end

  defp rpc_worker_errors(name) do
    case with_daemon_rpc(
           fn target ->
             :rpc.call(target, Severance.StatusPublisher.Worker, :errors, [name])
           end,
           quiet: true
         ) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @spec fetch_daemon_status() :: {:ok, Severance.Status.t()} | {:error, term()}
  defp fetch_daemon_status do
    case with_daemon_rpc(&rpc_countdown_status/1, quiet: true) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  @spec rpc_countdown_status(atom()) :: {:ok, Severance.Status.t()} | {:error, String.t()}
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

        {:ok, attach_version(status, version)}
    end
  end

  @doc false
  @spec attach_version(map(), String.t()) :: map()
  def attach_version(status, version) do
    Map.put(status, :version, version)
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
          {:ok, Severance.Status.t()} | {:error, term()},
          {:ok, String.t()} | {:error, term()}
        ) :: String.t()
  def format_status(daemon_result, update_result) do
    case daemon_result do
      {:ok, daemon} ->
        version = daemon.version
        header = "Severance v#{version}"
        overtime = if daemon.mode == :overtime, do: "active", else: "inactive"

        shutdown =
          cond do
            is_nil(daemon.shutdown_time) ->
              "not configured"

            daemon.minutes_remaining <= 0 ->
              "#{format_time(daemon.shutdown_time)} (passed)"

            true ->
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
