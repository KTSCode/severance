defmodule Severance.StatusPublisher.Worker do
  @moduledoc """
  Per-publisher GenServer. Schedules its own tick at `:interval_ms`,
  invokes the user fn inside a `Task` with a 2s timeout, and keeps
  a bounded ring of recent errors for `sev status` to surface.

  Runs `:teardown` at init (clearing stale sink state from a prior
  crash) and at terminate. Runs `:setup` once at init after teardown.
  """

  use GenServer

  require Logger

  @default_interval 60_000
  @publisher_timeout 2_000
  @max_errors 5

  @doc """
  Starts a worker for the given `{name, spec}` pair, registered under
  `Severance.StatusPublisher.Registry`.
  """
  @spec start_link({atom(), map()}) :: GenServer.on_start()
  def start_link({name, spec}) do
    GenServer.start_link(__MODULE__, {name, spec}, name: via(name))
  end

  @doc """
  Returns the bounded list of recent `{phase, reason, timestamp}`
  tuples recorded for this publisher.
  """
  @spec errors(atom()) :: [{atom(), term(), NaiveDateTime.t()}]
  def errors(name), do: GenServer.call(via(name), :errors)

  @doc """
  Invokes the publisher fn or teardown once and returns `:ok` or
  `{:error, reason}`. Used by `sev status --<name>` for debugging.
  """
  @spec invoke_once(atom(), :publish | :teardown) :: :ok | {:error, term()}
  def invoke_once(name, action), do: GenServer.call(via(name), {:invoke_once, action})

  @impl true
  def init({name, spec}) do
    Process.flag(:trap_exit, true)

    state = %{
      name: name,
      fun: Map.fetch!(spec, :fn),
      setup: Map.get(spec, :setup),
      teardown: Map.get(spec, :teardown),
      interval: Map.get(spec, :interval_ms, @default_interval),
      errors: []
    }

    safe_lifecycle(state, :teardown)
    safe_lifecycle(state, :setup)
    schedule(state.interval)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    safe_lifecycle(state, :teardown)
    :ok
  end

  @impl true
  def handle_call(:errors, _from, state), do: {:reply, state.errors, state}

  def handle_call({:invoke_once, :publish}, _from, state) do
    case safe_invoke(state) do
      :ok -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, record_error(state, :publish, elem(err, 1))}
    end
  end

  def handle_call({:invoke_once, :teardown}, _from, state) do
    safe_lifecycle(state, :teardown)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:publish, state) do
    state =
      case safe_invoke(state) do
        :ok -> state
        {:error, reason} -> record_error(state, :publish, reason)
      end

    schedule(state.interval)
    {:noreply, state}
  end

  # Task.async links to the caller. When a task exits (normally or not)
  # and trap_exit is set, the EXIT signal arrives as a message. Discard
  # these — outcomes are already handled in safe_invoke/safe_lifecycle.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp safe_invoke(%{fun: fun, name: name}) do
    task = Task.async(fn -> fun.(Severance.Countdown.status()) end)

    case Task.yield(task, @publisher_timeout) || Task.shutdown(task) do
      {:ok, _} ->
        :ok

      {:exit, reason} ->
        Logger.warning("publisher #{name} crashed: #{inspect(reason)}")
        {:error, {:crash, reason}}

      nil ->
        Logger.warning("publisher #{name} timed out")
        {:error, :timeout}
    end
  end

  defp safe_lifecycle(%{name: name} = state, phase) do
    case Map.get(state, phase) do
      nil ->
        :ok

      fun when is_function(fun, 0) ->
        task = Task.async(fn -> fun.() end)

        case Task.yield(task, @publisher_timeout) || Task.shutdown(task) do
          {:ok, _} ->
            :ok

          {:exit, reason} ->
            Logger.warning("publisher #{name} #{phase} crashed: #{inspect(reason)}")

          nil ->
            Logger.warning("publisher #{name} #{phase} timed out")
        end
    end
  end

  defp record_error(state, phase, reason) do
    entry = {phase, reason, NaiveDateTime.local_now()}
    %{state | errors: Enum.take([entry | state.errors], @max_errors)}
  end

  defp schedule(ms), do: Process.send_after(self(), :publish, ms)

  defp via(name), do: {:via, Registry, {Severance.StatusPublisher.Registry, name}}
end
