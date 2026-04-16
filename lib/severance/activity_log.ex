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

  defp format_timestamp(ndt) do
    Calendar.strftime(ndt, "%Y-%m-%dT%H:%M:%S")
  end
end
