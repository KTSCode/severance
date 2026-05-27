defmodule Severance.StatusPublisher.Tmux.Panes do
  @moduledoc """
  Tmux pane activity queries. Used by `Severance.Countdown` to find
  panes that have been idle past the stale threshold so the user can
  be nudged to close them.
  """

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
