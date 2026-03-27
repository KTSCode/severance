defmodule Severance.CLI do
  @moduledoc """
  Handles CLI argument parsing and the Overtime Protocol RPC connection.

  ## Usage

      severance                        # Start the daemon
      severance --shutdown-time HH:MM  # Start with custom shutdown time
      severance otp                    # Activate Overtime Protocol on running daemon
  """

  @doc """
  Parses command-line arguments into an action atom.

  Returns `:start` for no args or unrecognized args, `{:start, opts}` when
  options are provided, or `:overtime` when the `otp` subcommand is given.

  ## Examples

      iex> Severance.CLI.parse_args([])
      :start

      iex> Severance.CLI.parse_args(["otp"])
      :overtime

      iex> Severance.CLI.parse_args(["something-else"])
      :start
  """
  @spec parse_args([String.t()]) :: :start | {:start, keyword()} | :overtime
  def parse_args(["otp" | _rest]), do: :overtime

  def parse_args(["--shutdown-time", time_str | _rest]) do
    {:ok, time} = Time.from_iso8601(time_str <> ":00")
    {:start, shutdown_time: time}
  end

  def parse_args(_args), do: :start

  @doc """
  Connects to the running severance node and activates the Overtime Protocol.

  Starts a temporary named node, connects to the daemon, makes an RPC call
  to `Severance.Countdown.overtime/0`, then returns the result.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec run_overtime() :: :ok | {:error, String.t()}
  def run_overtime do
    hostname = node_hostname()
    target = :"severance@#{hostname}"
    cli_name = :"severance_cli_#{:rand.uniform(100_000)}@#{hostname}"

    Node.start(cli_name, name_domain: :shortnames)
    Node.set_cookie(Node.self(), cookie())

    case Node.connect(target) do
      true ->
        :rpc.call(target, Severance.Countdown, :overtime, [])
        IO.puts("Overtime Protocol activated. No shutdown today — but you'll hear about it.")
        :ok

      false ->
        IO.puts("Could not connect to severance daemon. Is it running?")
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
end
