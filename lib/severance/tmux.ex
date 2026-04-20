defmodule Severance.Tmux do
  @moduledoc """
  Tmux interaction helpers for status bar manipulation and
  stale pane detection.
  """

  @doc """
  Reads the current tmux global `status-right` value.
  """
  @spec capture_status_right() :: String.t()
  def capture_status_right do
    {output, 0} = system().tmux_cmd(["show-option", "-gv", "status-right"])
    String.trim(output)
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

    "#[fg=#{color},bold#{extra}] sev #{format_remaining(minutes_left)} #[default]#{original_status}"
  end

  @doc """
  Formats the time remaining until shutdown as a short tmux-friendly
  string. Returns whole hours (e.g. `"10h"`) when at or above one hour,
  otherwise minutes (e.g. `"45m"`). Partial hours round down.
  """
  @spec format_remaining(non_neg_integer()) :: String.t()
  def format_remaining(minutes) when minutes >= 60, do: "#{div(minutes, 60)}h"
  def format_remaining(minutes), do: "#{minutes}m"

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
