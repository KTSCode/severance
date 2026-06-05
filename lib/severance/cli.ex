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
      sev help                         # Print top-level usage (alias for sev --help)
      sev help --agent                 # Print LLM-agent usage with full config reference
      sev <cmd> --help                 # Print usage for a subcommand (e.g. sev status --help)
  """

  alias CliMate.CLI, as: Mate
  alias Severance.StatusPublisher.Tmux.ConfScanner

  @subcommand_names ~w(start init update version status log otp overtime over_time_protocol help)

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
      over_time_protocol: [options: []],
      help: [
        options: [
          agent: [type: :boolean, default: false, doc: "Print LLM-agent usage with full config reference"]
        ]
      ]
    ]
  ]

  @type parse_args_result :: Mate.parsed() | {:help, [atom()] | :agent} | {:error, String.t()}

  @doc """
  Parses command-line arguments into a CliMate parsed map, `:help`, or an error.

  Returns a `CliMate.CLI.parsed()` map with `:path`, `:options`, and `:arguments` keys
  on success. The `:path` is a single-element list identifying the matched subcommand,
  e.g. `[:start]`, `[:status]`, `[:otp]`.

  Returns `{:help, path}` when `--help` is passed. The `path` carries the
  resolved subcommand (e.g. `[:status]`), or `[]` for top-level help, so the
  caller can render subcommand-specific usage. The `help` subcommand resolves
  to top-level help (`{:help, []}`), an alias for `sev --help`.
  Returns `{:help, :agent}` for `sev help --agent`, which renders the
  LLM-agent usage reference instead of a subcommand path.
  Returns `{:error, message}` for unrecognized commands or invalid options.

  ## Examples

      iex> Severance.CLI.parse_args(["otp"]).path
      [:otp]

      iex> Severance.CLI.parse_args([]).path
      [:start]

      iex> Severance.CLI.parse_args(["status", "tmux_countdown"]).arguments.publisher
      "tmux_countdown"

      iex> match?({:error, _}, Severance.CLI.parse_args(["something-else"]))
      true

      iex> Severance.CLI.parse_args(["help"])
      {:help, []}

      iex> Severance.CLI.parse_args(["help", "--agent"])
      {:help, :agent}
  """
  @spec parse_args([String.t()]) :: parse_args_result()
  def parse_args(argv) do
    case argv |> normalize_argv() |> Mate.parse(@command) do
      {:ok, %{options: %{help: true}, path: path}} -> {:help, path}
      {:ok, %{path: [:help], options: %{agent: true}}} -> {:help, :agent}
      {:ok, %{path: [:help]}} -> {:help, []}
      {:ok, parsed} -> parsed
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @doc """
  Returns the CliMate-generated usage block for the `sev` command or a subcommand.

  With an empty path (the default) the top-level usage is returned. A path
  identifying a subcommand, e.g. `[:status]`, returns that subcommand's usage,
  including its positional arguments and options.
  """
  @spec usage([atom()]) :: String.t()
  def usage(path \\ [])

  def usage([]) do
    @command
    |> Mate.format_usage(ansi_enabled: false)
    |> IO.iodata_to_binary()
  end

  def usage([sub | _]) do
    spec = @command |> Keyword.fetch!(:subcommands) |> Keyword.fetch!(sub)

    [name: "#{@command[:name]} #{sub}"]
    |> Keyword.merge(spec)
    |> Mate.format_usage(ansi_enabled: false)
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns a self-contained usage reference written for LLM agents.

  Unlike `usage/1`, which mirrors the terse human-facing flag listing, this
  reference is a single document an agent can consume in one shot: the full
  command set, the configuration resolution order, every config key, the
  publisher spec contract, and the `Severance.Status` fields a publisher
  receives. Rendered by `sev help --agent`.
  """
  @spec agent_usage() :: String.t()
  def agent_usage do
    """
    # Severance — LLM agent reference

    Severance is a macOS background daemon that enforces a hard daily computer
    shutdown with escalating warnings. It runs as a LaunchAgent, starts at
    login, and is controlled through the `sev` CLI. The CLI talks to the
    running daemon over BEAM distribution (RPC) for live commands like
    overtime and status.

    ## Commands

    #{usage()}
    Bare `sev` (or `sev start`) starts the daemon; `sev <cmd> --help` prints
    one command's flags. `otp`, `overtime`, and `over_time_protocol` are
    aliases for the Overtime Protocol, which cancels today's shutdown and
    fires a 60-second notification burst instead.

    ## Configuration resolution

    Config is layered; highest priority wins:

      1. CLI flag             sev --shutdown-time 17:00
      2. Environment variable SEVERANCE_SHUTDOWN_TIME=16:30 sev
      3. Config file          ~/.config/severance/config.exs
      4. Compiled defaults

    ## Config file

    `~/.config/severance/config.exs` is NOT inert data — it is evaluated as
    Elixir via `Code.eval_file/1` with full process privileges. Only edit it
    if you control the directory. The file must evaluate to a single map.
    These are the compiled defaults (each key may be overridden):

    #{indent(inspect(Severance.Config.defaults(), pretty: true))}

    Key semantics:

      shutdown_time           String "HH:MM". When the machine powers off.
      overtime_notifications  Boolean. When false, suppresses the notification
                              burst during overtime or when starting after the
                              shutdown time.
      log_file                String path (~ is expanded) for the activity log.
      publishers              Map of publisher specs (see below).

    ## Publisher spec contract

    `publishers` maps an atom key (your choice) to a spec map. Specs run on the
    daemon and push status to a sink (tmux var, file, dbus, notification, ...).

      :fn           (Severance.Status.t() -> any())   required
      :interval_ms  non_neg_integer()                 optional, default 60_000
      :tmux_var     String.t()                        optional
      :setup        (-> any())                         optional
      :teardown     (-> any())                         optional

    Lifecycle: on start the worker runs :teardown (clearing stale state from a
    prior crash) then :setup; :fn fires every :interval_ms. On clean shutdown
    :teardown runs again. A SIGKILL skips :teardown — the next start clears it.

    Writing to tmux is the :fn's job — it is NOT automatic. The :fn must call
    `Severance.StatusPublisher.Tmux.set_var("countdown", str)` to write the
    user variable `@sev_countdown`, and :teardown should call `clear_var/1`.
    A bare :fn that only returns a string writes nothing. The `publisher/2`
    builder wires this for you:

        Severance.StatusPublisher.Tmux.publisher("countdown", fn status -> ... end)

    returns a complete spec whose :fn calls set_var/2, :teardown calls
    clear_var/1, plus :tmux_var and :interval_ms.

    :tmux_var itself is only metadata: `sev status` uses it to check whether
    ~/.tmux.conf references `@sev_<var>` and warns if not. It triggers no
    write on its own. Reference the variable from ~/.tmux.conf, e.g.:

        set -ag status-right "\#{@sev_countdown}"

    Example file-writing publisher:

        publishers: %{
          polybar: %{
            fn: fn status -> File.write!("/tmp/sev", "\#{status.minutes_remaining}m") end,
            teardown: fn -> File.rm("/tmp/sev") end,
            interval_ms: 30_000
          }
        }

    ## Severance.Status fields passed to every :fn

    #{status_fields_block()}

    ## Workflow recipes

    Task-oriented sequences. Pick the recipe, run the steps in order.

    First-time setup:
      1. sev init                 (writes config + LaunchAgent plist)
      2. cp rel/com.severance.daemon.plist ~/Library/LaunchAgents/
      3. launchctl load ~/Library/LaunchAgents/com.severance.daemon.plist
      4. sev                      (start now without waiting for next login)

    Set a custom shutdown time (three ways; highest precedence wins):
      - Persistent: edit shutdown_time in ~/.config/severance/config.exs,
        then restart the daemon (sev stop is not exposed; relaunch the
        LaunchAgent or reboot — or for a one-off, use a flag/env below).
      - This launch only: SEVERANCE_SHUTDOWN_TIME=16:30 sev
      - This launch only: sev --shutdown-time 16:30

    Keep working past shutdown:
      - sev otp                   (cancels today's shutdown; fires a
        60-second notification burst instead, then trusts you)
      - Set overtime_notifications: false in config to silence that burst.

    Add a status-bar publisher (tmux):
      1. Add a publisher whose :fn actually writes the tmux var — easiest is
         the Severance.StatusPublisher.Tmux.publisher/2 builder, whose :fn
         calls set_var/2 for you. A bare :fn that only returns a string (or
         only sets :tmux_var) writes nothing. See Publisher spec contract.
      2. sev init                 (prints the exact ~/.tmux.conf paste block
         for any tmux_var not yet referenced)
      3. Paste the line into ~/.tmux.conf, then: tmux source-file ~/.tmux.conf
      4. sev status <publisher>   (invoke once to verify the formatter)
      5. sev status               (the tmux wiring block flags a missing ref)

    Diagnose "it didn't shut down" or "is it running":
      1. sev status               (running?, shutdown time, minutes remaining,
         overtime active?, missing tmux wiring, recent publisher errors)
      2. sev log                  (activity log: started / overtime events)

    See docs/configuration.md for the complete publisher and tmux reference.
    """
  end

  # One-line type/description per Severance.Status field. Field names are
  # not listed here — they are read from the struct so a new field cannot
  # silently drop out of the agent reference. A field without an entry
  # still renders (with no description).
  @status_field_docs %{
    mode: ":severance | :overtime",
    phase: ":waiting | :gentle | :aggressive | :final | :shutdown | :done",
    shutdown_time: "Time.t() | nil",
    minutes_remaining: "integer() | nil  (negative once past shutdown)",
    seconds_remaining: "integer() | nil",
    version: "String.t() | nil",
    update_available?: "boolean() | nil",
    log_path: "String.t() | nil"
  }

  @spec status_fields_block() :: String.t()
  defp status_fields_block do
    %Severance.Status{}
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map_join("\n", fn field ->
      "      :#{field}  #{Map.get(@status_field_docs, field, "")}"
    end)
  end

  @spec indent(String.t()) :: String.t()
  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
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
      "--help" in argv -> argv
      Enum.any?(argv, &(&1 in @subcommand_names)) -> argv
      true -> ["start" | argv]
    end
  end

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

  The `:publisher_name` atom is created upstream in `Severance.Application`
  from the CliMate-parsed positional argument via `String.to_atom/1`. Arbitrary
  user-defined publisher names are accepted because they come from user config
  evaluated with `Code.eval_file/1` (same trust model as the rest of the config
  pipeline).

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
