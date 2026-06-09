defmodule Severance.StatusPublisher.Tmux.Format do
  @moduledoc """
  Optional helpers for users writing tmux-targeted publisher formatters.
  Non-tmux sinks ignore these. Phase color and blink come from
  `Severance.Phase`, the single source of truth for phase attributes.
  """

  alias Severance.Phase

  @doc """
  Returns a tmux color (256-color name) for the given countdown phase.

  Accepts an optional 3-element palette ordered
  `[waiting_or_gentle, aggressive, final_or_shutdown]`. Default palette:
  `["colour51", "colour226", "colour196"]`.

      iex> Severance.StatusPublisher.Tmux.Format.color_for_phase(:waiting)
      "colour51"
      iex> Severance.StatusPublisher.Tmux.Format.color_for_phase(:final, ["a", "b", "c"])
      "c"
  """
  @spec color_for_phase(Severance.Status.phase(), [String.t()]) :: String.t()
  def color_for_phase(phase, palette \\ Phase.default_palette()) do
    Phase.color(phase, palette)
  end

  @doc """
  Returns the tmux `,blink` suffix when the given phase should blink,
  empty string otherwise.

      iex> Severance.StatusPublisher.Tmux.Format.blink_for_phase(:aggressive)
      ",blink"
      iex> Severance.StatusPublisher.Tmux.Format.blink_for_phase(:waiting)
      ""
  """
  @spec blink_for_phase(Severance.Status.phase()) :: String.t()
  def blink_for_phase(phase) do
    if Phase.blink?(phase), do: ",blink", else: ""
  end
end
