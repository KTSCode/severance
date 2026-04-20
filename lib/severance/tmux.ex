defmodule Severance.Tmux do
  @moduledoc """
  Tmux interaction helpers for status bar manipulation and
  stale pane detection.
  """

  # Matches the exact banner prefix emitted by `countdown_status/3`.
  # Anchored to the start of the string so unrelated user widgets
  # whose text happens to contain `sev:` are not mistaken for the
  # daemon's own banner.
  @sev_prefix_regex ~r/\A#\[fg=colour\d+,bold(?:,blink)?\] sev:\S+ #\[default\]/

  @doc """
  Reads the current tmux global `status-right` value.

  Returns `:error` when tmux is unavailable (e.g. no server has been
  started yet). Severance runs as a LaunchAgent that boots before the
  user opens a tmux session, so callers must distinguish "no tmux
  server" from "tmux server with an empty status-right" instead of
  treating both as the empty string.
  """
  @spec capture_status_right() :: {:ok, String.t()} | :error
  def capture_status_right do
    case system().tmux_cmd(["show-option", "-gv", "status-right"]) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> :error
    end
  end

  @doc """
  Removes the Severance `sev:` banner prefix from a captured
  `status-right` value.

  Only strips when the string begins with the exact banner pattern
  produced by `countdown_status/3`. User widgets that merely contain
  the substring `sev:` are left untouched.
  """
  @spec strip_sev_prefix(String.t()) :: String.t()
  def strip_sev_prefix(status) do
    Regex.replace(@sev_prefix_regex, status, "")
  end

  @doc """
  Sets tmux global `status-right` to the given value.
  """
  @spec set_status_right(String.t()) :: :ok
  def set_status_right(value) do
    system().tmux_cmd(["set-option", "-g", "status-right", value])
    :ok
  end

  @doc """
  Builds the countdown status string for a given phase.
  Prepends a colored `sev` prefix with the time remaining to the
  original status.

  The `:waiting` phase uses cyan and is shown while Severance is idle
  outside the escalation window. Other phases follow the color pattern
  in the README.
  """
  @spec countdown_status(
          non_neg_integer(),
          :waiting | :gentle | :aggressive | :final,
          String.t()
        ) :: String.t()
  def countdown_status(minutes_left, phase, original_status) do
    {color, extra} =
      case phase do
        :waiting -> {"colour51", ""}
        :gentle -> {"colour226", ""}
        :aggressive -> {"colour196", ",blink"}
        :final -> {"colour196", ",blink"}
      end

    "#[fg=#{color},bold#{extra}] sev:#{format_remaining(minutes_left)} #[default]#{original_status}"
  end

  @doc """
  Formats the time remaining until shutdown as a short tmux-friendly
  string. Combines hours and minutes when both are nonzero
  (e.g. `"5h12m"`), drops minutes on exact hour boundaries
  (e.g. `"2h"`), and shows minutes only when under one hour
  (e.g. `"45m"`).
  """
  @spec format_remaining(non_neg_integer()) :: String.t()
  def format_remaining(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)

    cond do
      hours == 0 -> "#{mins}m"
      mins == 0 -> "#{hours}h"
      true -> "#{hours}h#{mins}m"
    end
  end

  @doc """
  Queries tmux for all panes and returns those with no activity
  in the last `stale_threshold_minutes` minutes.
  """
  @spec stale_panes(non_neg_integer()) :: [%{pane: String.t(), path: String.t()}]
  def stale_panes(stale_threshold_minutes) do
    {output, _} =
      system().tmux_cmd([
        "list-panes",
        "-a",
        "-F",
        "\#{session_name}:\#{window_name}.\#{pane_index}\t\#{pane_current_path}\t\#{pane_activity}"
      ])

    cutoff = System.os_time(:second) - stale_threshold_minutes * 60
    parse_stale_panes(output, cutoff)
  end

  @doc """
  Parses raw tmux pane output and returns panes with last activity
  before the given cutoff (unix timestamp in seconds).
  """
  @spec parse_stale_panes(String.t(), integer()) :: [%{pane: String.t(), path: String.t()}]
  def parse_stale_panes(raw_output, cutoff) do
    raw_output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_pane_line(&1, cutoff))
  end

  defp parse_pane_line(line, cutoff) do
    case String.split(line, "\t") do
      [pane, path, activity_str] -> stale_entry(pane, path, activity_str, cutoff)
      _ -> []
    end
  end

  defp stale_entry(pane, path, activity_str, cutoff) do
    case Integer.parse(activity_str) do
      {activity, ""} when activity < cutoff -> [%{pane: pane, path: path}]
      _ -> []
    end
  end

  defp system, do: Severance.System.adapter()
end
