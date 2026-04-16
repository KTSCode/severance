defmodule Severance.ActivityLog do
  @moduledoc """
  Writes timestamped activity entries to a plain-text log file.

  Tracks daemon sessions (start/stop with duration) and overtime
  protocol activations. Each entry is one line, greppable:

      2026-04-15T10:00:00 started
      2026-04-15T16:45:00 overtime
      2026-04-15T18:30:00 stopped duration_minutes=510
  """

  @default_log_file Path.join([System.user_home!(), ".local", "state", "severance", "activity.log"])

  @doc """
  Returns the default log file path (`~/.local/state/severance/activity.log`).
  """
  @spec default_log_file() :: String.t()
  def default_log_file, do: @default_log_file

  @doc """
  Formats a log entry as a single line string.

  ## Options

  - `:timestamp` — `NaiveDateTime.t()` for the entry (required)
  - `:duration_minutes` — integer minutes, included for `:stopped` events
  """
  @spec format_entry(:started | :overtime | :stopped, keyword()) :: String.t()
  def format_entry(event, opts) do
    timestamp = Keyword.fetch!(opts, :timestamp)
    ts_str = format_timestamp(timestamp)
    base = "#{ts_str} #{event}"

    case Keyword.get(opts, :duration_minutes) do
      nil -> base
      minutes -> "#{base} duration_minutes=#{minutes}"
    end
  end

  @doc """
  Logs a daemon started event. Stores the start time in Application env
  for duration calculation when the daemon stops.
  """
  @spec log_started(String.t()) :: :ok
  def log_started(log_file) do
    now = local_now()
    Application.put_env(:severance, :activity_log_started_at, now)
    append(log_file, format_entry(:started, timestamp: now))
  end

  @doc """
  Logs an overtime protocol activation event.
  """
  @spec log_overtime(String.t()) :: :ok
  def log_overtime(log_file) do
    append(log_file, format_entry(:overtime, timestamp: local_now()))
  end

  @doc """
  Logs a daemon stopped event with session duration in minutes.

  Duration is calculated from the start time stored by `log_started/1`.
  If no start time is available (abnormal state), logs without duration.
  """
  @spec log_stopped(String.t()) :: :ok
  def log_stopped(log_file) do
    now = local_now()

    opts =
      case Application.get_env(:severance, :activity_log_started_at) do
        nil ->
          [timestamp: now]

        started_at ->
          duration = NaiveDateTime.diff(now, started_at, :minute)
          [timestamp: now, duration_minutes: duration]
      end

    append(log_file, format_entry(:stopped, opts))
  end

  defp append(log_file, line) do
    log_file |> Path.dirname() |> File.mkdir_p!()
    File.write!(log_file, line <> "\n", [:append])
    :ok
  end

  defp local_now do
    case Application.get_env(:severance, :now_fn) do
      nil -> NaiveDateTime.local_now()
      fun -> fun.()
    end
  end

  defp format_timestamp(ndt) do
    Calendar.strftime(ndt, "%Y-%m-%dT%H:%M:%S")
  end
end
