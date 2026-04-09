defmodule Severance.Countdown do
  @moduledoc """
  GenServer that manages the shutdown countdown state machine.

  Phases: waiting -> gentle -> aggressive -> final -> shutdown/overtime -> done

  Sleeps until T-30 before the configured shutdown time, then ticks
  through phases with escalating notifications and tmux status updates.
  On weekends, hard shutdown is disabled regardless of mode.
  """

  use GenServer

  alias Severance.Notifier
  alias Severance.Tmux

  require Logger

  @gentle_interval_ms 5 * 60 * 1000
  @aggressive_interval_ms 2 * 60 * 1000
  @final_interval_ms 60 * 1000
  @overtime_burst_interval_ms 5 * 1000
  @overtime_burst_count 12
  @stale_threshold_minutes 15
  @wait_poll_ms 60_000
  @shutdown_retry_ms 60_000

  defstruct [
    :shutdown_time,
    :original_tmux_status,
    mode: :severance,
    phase: :waiting
  ]

  # --- Public API ---

  @doc """
  Starts the countdown GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    shutdown_time = Keyword.fetch!(opts, :shutdown_time)
    mode = Keyword.get(opts, :mode, :severance)
    GenServer.start_link(__MODULE__, {shutdown_time, mode}, name: __MODULE__)
  end

  @doc """
  Activates the Overtime Protocol. The daemon will send annoying
  notifications at T-0 instead of shutting down the machine.
  """
  @spec overtime() :: :ok
  def overtime do
    GenServer.call(__MODULE__, :overtime)
  end

  @doc """
  Returns the current mode (`:severance` or `:overtime`).
  """
  @spec mode() :: :severance | :overtime
  def mode do
    GenServer.call(__MODULE__, :mode)
  end

  @doc """
  Returns status information for the running daemon.

  Includes mode, phase, configured shutdown time, and minutes remaining.
  """
  @spec status() :: %{
          mode: :severance | :overtime,
          phase: :waiting | :gentle | :aggressive | :final | :shutdown | :done,
          shutdown_time: Time.t(),
          minutes_remaining: integer()
        }
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Returns the phase for a given number of minutes remaining.
  """
  @spec phase_for_remaining(integer()) :: :gentle | :aggressive | :final | :shutdown
  def phase_for_remaining(minutes) when minutes > 15, do: :gentle
  def phase_for_remaining(minutes) when minutes > 5, do: :aggressive
  def phase_for_remaining(minutes) when minutes > 0, do: :final
  def phase_for_remaining(_minutes), do: :shutdown

  @doc """
  Returns the tick interval in milliseconds for a given phase.
  """
  @spec tick_interval_ms(:gentle | :aggressive | :final) :: non_neg_integer()
  def tick_interval_ms(:gentle), do: @gentle_interval_ms
  def tick_interval_ms(:aggressive), do: @aggressive_interval_ms
  def tick_interval_ms(:final), do: @final_interval_ms

  @doc """
  Returns true if the given date falls on a weekend.
  """
  @spec weekend?(Date.t()) :: boolean()
  def weekend?(date) do
    Date.day_of_week(date) in [6, 7]
  end

  @doc """
  Returns true if the given shutdown time has already passed today.
  """
  @spec past_shutdown?(Time.t()) :: boolean()
  def past_shutdown?(shutdown_time) do
    now = NaiveDateTime.to_time(local_now())
    Time.compare(now, shutdown_time) != :lt
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({shutdown_time, mode}) do
    state = %__MODULE__{shutdown_time: shutdown_time, mode: mode}
    schedule_countdown_start(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:overtime, _from, state) do
    {:reply, :ok, %{state | mode: :overtime}}
  end

  @impl true
  def handle_call(:mode, _from, state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      mode: state.mode,
      phase: state.phase,
      shutdown_time: state.shutdown_time,
      minutes_remaining: minutes_remaining(state.shutdown_time)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:start_countdown, state) do
    original_status = Tmux.capture_status_right()
    state = %{state | original_tmux_status: original_status, phase: :gentle}
    tick()
    {:noreply, state}
  end

  @impl true
  def handle_info(:late_start, state) do
    original_status = Tmux.capture_status_right()
    state = %{state | original_tmux_status: original_status}

    case effective_mode(state) do
      :severance ->
        handle_shutdown(state)
        {:noreply, %{state | phase: :done}}

      :overtime ->
        if Application.get_env(:severance, :overtime_notifications, true) do
          Process.send_after(self(), {:overtime_burst, @overtime_burst_count}, 0)
          {:noreply, state}
        else
          Tmux.set_status_right(original_status)
          {:noreply, %{state | phase: :done}}
        end
    end
  end

  @impl true
  def handle_info(:tick, state) do
    minutes_left = minutes_remaining(state.shutdown_time)
    phase = phase_for_remaining(minutes_left)
    state = %{state | phase: phase}

    case phase do
      :shutdown ->
        handle_shutdown(state)
        {:noreply, %{state | phase: :done}}

      _ ->
        Notifier.send_countdown(minutes_left, effective_mode(state), phase)

        Tmux.set_status_right(Tmux.countdown_status(minutes_left, phase, state.original_tmux_status))

        if phase == :aggressive and minutes_left == 15 do
          send_stale_pane_warnings()
        end

        schedule_tick(phase)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:retry_shutdown, state) do
    Severance.System.adapter().shutdown_machine()
    Process.send_after(self(), :retry_shutdown, @shutdown_retry_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:overtime_burst, 0}, state) do
    Tmux.set_status_right(state.original_tmux_status)
    {:noreply, %{state | phase: :done}}
  end

  @impl true
  def handle_info({:overtime_burst, remaining}, state) do
    Notifier.send_overtime_burst()
    Process.send_after(self(), {:overtime_burst, remaining - 1}, @overtime_burst_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_countdown_start, state) do
    cond do
      past_shutdown?(state.shutdown_time) ->
        Logger.info("Started after shutdown time.")
        send(self(), :late_start)

      ms_until_countdown_start(state.shutdown_time) <= 0 ->
        send(self(), :start_countdown)

      true ->
        Process.send_after(self(), :check_countdown_start, @wait_poll_ms)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_countdown_start(state) do
    ms = ms_until_countdown_start(state.shutdown_time)

    cond do
      past_shutdown?(state.shutdown_time) ->
        Logger.info("Started after shutdown time.")
        send(self(), :late_start)

      ms > 0 ->
        Process.send_after(self(), :check_countdown_start, @wait_poll_ms)

      true ->
        send(self(), :start_countdown)
    end
  end

  defp schedule_tick(phase) do
    Process.send_after(self(), :tick, tick_interval_ms(phase))
  end

  defp tick do
    send(self(), :tick)
    :ok
  end

  defp handle_shutdown(state) do
    case effective_mode(state) do
      :severance ->
        Notifier.send_countdown(0, :severance, :final)
        Tmux.set_status_right(state.original_tmux_status)
        Severance.System.adapter().shutdown_machine()
        Process.send_after(self(), :retry_shutdown, @shutdown_retry_ms)

      :overtime ->
        if Application.get_env(:severance, :overtime_notifications, true) do
          Process.send_after(self(), {:overtime_burst, @overtime_burst_count}, 0)
        else
          Tmux.set_status_right(state.original_tmux_status)
        end
    end
  end

  defp effective_mode(state) do
    if weekend?(NaiveDateTime.to_date(local_now())) do
      :overtime
    else
      state.mode
    end
  end

  defp minutes_remaining(shutdown_time) do
    now = NaiveDateTime.to_time(local_now())
    Time.diff(shutdown_time, now, :minute)
  end

  defp ms_until_countdown_start(shutdown_time) do
    countdown_start = Time.add(shutdown_time, -30, :minute)
    now = NaiveDateTime.to_time(local_now())
    Time.diff(countdown_start, now, :millisecond)
  end

  defp local_now do
    case Application.get_env(:severance, :now_fn) do
      nil -> NaiveDateTime.local_now()
      fun -> fun.()
    end
  end

  defp send_stale_pane_warnings do
    @stale_threshold_minutes
    |> Tmux.stale_panes()
    |> Enum.each(&Notifier.send_stale_pane(&1, @stale_threshold_minutes))
  end
end
