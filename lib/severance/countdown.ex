defmodule Severance.Countdown do
  @moduledoc """
  GenServer that manages the shutdown countdown state machine.

  Phases: waiting -> gentle -> aggressive -> final -> shutdown/overtime -> done

  Sleeps until T-30 before the configured shutdown time, then ticks
  through phases with escalating notifications and tmux status updates.
  On weekends, hard shutdown is disabled regardless of mode.
  """

  use GenServer

  alias Severance.ActivityLog
  alias Severance.Notifier
  alias Severance.Phase
  alias Severance.StatusPublisher.Tmux.Panes

  require Logger

  @overtime_burst_interval_ms 5 * 1000
  @overtime_burst_count 12
  @stale_threshold_minutes 15
  @wait_poll_ms 60_000
  @shutdown_retry_ms 60_000

  @type t :: %__MODULE__{
          shutdown_time: Time.t() | nil,
          mode: :severance | :overtime,
          phase: :waiting | :gentle | :aggressive | :final | :shutdown | :done,
          day: Date.t() | nil,
          timer_ref: reference() | nil
        }

  defstruct [
    :shutdown_time,
    :day,
    :timer_ref,
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

  Includes mode, phase, configured shutdown time, minutes remaining,
  and seconds remaining.
  """
  @spec status() :: Severance.Status.t()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Re-arms the countdown with a newly resolved `shutdown_time`, cancelling
  whatever timer is currently pending. `mode` and `day` are preserved.
  """
  @spec reload(Time.t()) :: :ok
  def reload(shutdown_time) do
    GenServer.call(__MODULE__, {:reload, shutdown_time})
  end

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

  @doc """
  Returns milliseconds from the given moment until the next local midnight.

  ## Examples

      iex> Severance.Countdown.ms_until_midnight(~N[2026-04-09 23:00:00])
      3600000

  """
  @spec ms_until_midnight(NaiveDateTime.t()) :: non_neg_integer()
  def ms_until_midnight(now) do
    next_midnight =
      now
      |> NaiveDateTime.to_date()
      |> Date.add(1)
      |> NaiveDateTime.new!(~T[00:00:00])

    NaiveDateTime.diff(next_midnight, now, :millisecond)
  end

  @doc """
  Decides the next state for a midnight-reset tick at `current_day`.

  Overtime is a single-day opt-out, so once the local date advances past the
  session's day the daemon starts the new day clean: back to severance mode,
  waiting for the configured shutdown time. The reset timer fires on monotonic
  time while the interval to midnight is wall-clock, so a DST transition can
  fire it before the wall clock crosses midnight; in that case the date has
  not advanced and the session is left untouched.

  Returns `{:reset, fresh_state}` on a day rollover, or `{:wait, state}` when
  the date has not advanced yet.
  """
  @spec reset_state(t(), Date.t()) :: {:reset, t()} | {:wait, t()}
  def reset_state(%__MODULE__{day: day} = state, current_day) do
    if Date.after?(current_day, day) do
      {:reset, %__MODULE__{shutdown_time: state.shutdown_time, day: current_day}}
    else
      {:wait, state}
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({shutdown_time, mode}) do
    state = %__MODULE__{shutdown_time: shutdown_time, mode: mode, day: today()}
    state = schedule_countdown_start(state)
    schedule_midnight_reset()
    {:ok, state}
  end

  @impl true
  def handle_call(:overtime, _from, state) do
    log_file = Application.get_env(:severance, :log_file, ActivityLog.default_log_file())
    ActivityLog.log_overtime(log_file)
    {:reply, :ok, %{state | mode: :overtime}}
  end

  @impl true
  def handle_call(:mode, _from, state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_call({:reload, shutdown_time}, _from, state) do
    state =
      state
      |> cancel_timer()
      |> then(&%{&1 | shutdown_time: shutdown_time, phase: :waiting})
      |> schedule_countdown_start()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    minutes = minutes_remaining(state.shutdown_time)

    status = %Severance.Status{
      mode: state.mode,
      phase: state.phase,
      shutdown_time: state.shutdown_time,
      minutes_remaining: minutes,
      seconds_remaining: seconds_remaining(state.shutdown_time),
      log_path: Application.get_env(:severance, :log_file)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:start_countdown, state) do
    state = %{state | phase: :gentle}
    tick()
    {:noreply, state}
  end

  @impl true
  def handle_info(:late_start, state) do
    case effective_mode(state) do
      :severance ->
        handle_shutdown(state)
        {:noreply, %{state | phase: :done}}

      :overtime ->
        if Application.get_env(:severance, :overtime_notifications, true) do
          Process.send_after(self(), {:overtime_burst, @overtime_burst_count}, 0)
          {:noreply, state}
        else
          {:noreply, %{state | phase: :done}}
        end
    end
  end

  @impl true
  def handle_info(:tick, state) do
    minutes_left = minutes_remaining(state.shutdown_time)
    phase = Phase.phase_for_remaining(minutes_left)
    state = %{state | phase: phase}

    case phase do
      :shutdown ->
        handle_shutdown(state)
        {:noreply, %{state | phase: :done}}

      _ ->
        Notifier.send_countdown(minutes_left, effective_mode(state), phase)

        if phase == :aggressive and minutes_left == 15 do
          send_stale_pane_warnings()
        end

        ref = schedule_tick(phase)
        {:noreply, %{state | timer_ref: ref}}
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
    state =
      cond do
        past_shutdown?(state.shutdown_time) ->
          Logger.info("Started after shutdown time.")
          send(self(), :late_start)
          %{state | timer_ref: nil}

        ms_until_countdown_start(state.shutdown_time) <= 0 ->
          send(self(), :start_countdown)
          %{state | timer_ref: nil}

        true ->
          ref = Process.send_after(self(), :check_countdown_start, @wait_poll_ms)
          %{state | timer_ref: ref}
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:midnight_reset, state) do
    case reset_state(state, today()) do
      {:reset, fresh} ->
        Logger.info("Midnight reset — starting a fresh day.")
        fresh = schedule_countdown_start(fresh)
        schedule_midnight_reset()
        {:noreply, fresh}

      {:wait, state} ->
        schedule_midnight_reset()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    if normal_shutdown?(reason) do
      log_file = Application.get_env(:severance, :log_file, ActivityLog.default_log_file())
      ActivityLog.log_stopped(log_file)
    end

    :ok
  end

  # --- Private ---

  defp schedule_countdown_start(state) do
    ms = ms_until_countdown_start(state.shutdown_time)

    cond do
      past_shutdown?(state.shutdown_time) ->
        Logger.info("Started after shutdown time.")
        send(self(), :late_start)
        %{state | timer_ref: nil}

      ms > 0 ->
        ref = Process.send_after(self(), :check_countdown_start, @wait_poll_ms)
        %{state | timer_ref: ref}

      true ->
        send(self(), :start_countdown)
        %{state | timer_ref: nil}
    end
  end

  defp schedule_tick(phase) do
    Process.send_after(self(), :tick, Phase.interval_ms(phase))
  end

  defp schedule_midnight_reset do
    Process.send_after(self(), :midnight_reset, ms_until_midnight(local_now()))
  end

  # Cancels the pending timer (if any) and drains any transition messages
  # already in the mailbox. Unconditional: a nil timer_ref does not mean
  # the mailbox is clean — handle_info(:check_countdown_start, ...) and
  # schedule_countdown_start/1 both set timer_ref: nil right after
  # self-sending :late_start or :start_countdown, so a queued transition
  # can outlive the timer that (no longer) tracks it.
  defp cancel_timer(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    flush_transitions()
    %{state | timer_ref: nil}
  end

  # Recursive drain, not a single receive — more than one transition
  # message can be queued (e.g. a stale :check_countdown_start followed by
  # the :late_start it sent). Leaves :retry_shutdown and :overtime_burst
  # untouched — reload does not interrupt an in-progress shutdown or
  # overtime chain.
  defp flush_transitions do
    receive do
      msg when msg in [:tick, :check_countdown_start, :late_start, :start_countdown] ->
        flush_transitions()
    after
      0 -> :ok
    end
  end

  defp tick do
    send(self(), :tick)
    :ok
  end

  defp handle_shutdown(state) do
    case effective_mode(state) do
      :severance ->
        Notifier.send_countdown(0, :severance, :final)
        Severance.System.adapter().shutdown_machine()
        Process.send_after(self(), :retry_shutdown, @shutdown_retry_ms)

      :overtime ->
        if Application.get_env(:severance, :overtime_notifications, true) do
          Process.send_after(self(), {:overtime_burst, @overtime_burst_count}, 0)
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

  defp seconds_remaining(nil), do: nil

  defp seconds_remaining(shutdown_time) do
    now = NaiveDateTime.to_time(local_now())
    Time.diff(shutdown_time, now, :second)
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

  defp today do
    NaiveDateTime.to_date(local_now())
  end

  defp normal_shutdown?(:normal), do: true
  defp normal_shutdown?(:shutdown), do: true
  defp normal_shutdown?({:shutdown, _}), do: true
  defp normal_shutdown?(_), do: false

  defp send_stale_pane_warnings do
    @stale_threshold_minutes
    |> Panes.stale_panes()
    |> Enum.each(&Notifier.send_stale_pane(&1, @stale_threshold_minutes))
  end
end
