defmodule Severance.Phase do
  @moduledoc """
  Single source of truth for the escalating countdown phases.

  The shutdown countdown moves through phases as the configured shutdown
  time approaches:

      waiting -> gentle -> aggressive -> final -> shutdown | overtime -> done

  Each phase carries its own attributes — the minutes-remaining threshold
  at which it becomes active, the tick cadence, the notification sound, and
  the tmux status color and blink. Consumers (`Severance.Countdown`,
  `Severance.Notifier`, `Severance.StatusPublisher.Tmux.Format`) read those
  attributes from here rather than each owning a parallel copy, so adding or
  re-ordering a phase is a one-place edit.

  `:waiting`, `:shutdown`, and `:done` are not part of the escalating
  sequence proper — they have a status color but no tick cadence or sound.
  """

  @type name :: :waiting | :gentle | :aggressive | :final | :shutdown | :done

  @type t :: %{
          name: name(),
          min_minutes: non_neg_integer() | nil,
          interval_ms: pos_integer() | nil,
          sound: String.t() | nil,
          color_index: non_neg_integer(),
          blink?: boolean()
        }

  # Phases in escalation order. A phase with a `min_minutes` threshold is
  # active while `minutes_remaining > min_minutes`. `color_index` is the
  # position in a 3-element tmux palette ordered
  # `[waiting_or_gentle, aggressive, final_or_shutdown]`.
  @phases [
    %{name: :waiting, min_minutes: nil, interval_ms: nil, sound: nil, color_index: 0, blink?: false},
    %{name: :gentle, min_minutes: 15, interval_ms: 5 * 60 * 1000, sound: "Tink", color_index: 0, blink?: false},
    %{name: :aggressive, min_minutes: 5, interval_ms: 2 * 60 * 1000, sound: "Funk", color_index: 1, blink?: true},
    %{name: :final, min_minutes: 0, interval_ms: 60 * 1000, sound: "Basso", color_index: 2, blink?: true},
    %{name: :shutdown, min_minutes: nil, interval_ms: nil, sound: nil, color_index: 2, blink?: false},
    %{name: :done, min_minutes: nil, interval_ms: nil, sound: nil, color_index: 2, blink?: false}
  ]

  @by_name Map.new(@phases, &{&1.name, &1})

  @escalation_phases Enum.filter(@phases, &(&1.min_minutes != nil))

  @default_palette ["colour51", "colour226", "colour196"]

  @doc """
  Returns the phase for a given number of minutes remaining.

  Picks the first escalation phase whose threshold the remaining minutes
  exceed; once nothing is left it is `:shutdown`.

  ## Examples

      iex> Severance.Phase.phase_for_remaining(30)
      :gentle

      iex> Severance.Phase.phase_for_remaining(15)
      :aggressive

      iex> Severance.Phase.phase_for_remaining(5)
      :final

      iex> Severance.Phase.phase_for_remaining(0)
      :shutdown

  """
  @spec phase_for_remaining(integer()) :: :gentle | :aggressive | :final | :shutdown
  def phase_for_remaining(minutes) do
    Enum.find_value(@escalation_phases, :shutdown, fn phase ->
      if minutes > phase.min_minutes, do: phase.name
    end)
  end

  @doc """
  Returns the tick interval in milliseconds for a phase, or `nil` for
  phases that do not tick (`:waiting`, `:shutdown`, `:done`).

  ## Examples

      iex> Severance.Phase.interval_ms(:gentle)
      300000

      iex> Severance.Phase.interval_ms(:waiting)
      nil

  """
  @spec interval_ms(name()) :: pos_integer() | nil
  def interval_ms(phase), do: fetch(phase).interval_ms

  @doc """
  Returns the notification sound for a phase, or `nil` for phases that do
  not notify.

  ## Examples

      iex> Severance.Phase.sound(:gentle)
      "Tink"

      iex> Severance.Phase.sound(:final)
      "Basso"

  """
  @spec sound(name()) :: String.t() | nil
  def sound(phase), do: fetch(phase).sound

  @doc """
  Returns the tmux color (256-color name) for a phase.

  Accepts an optional 3-element palette ordered
  `[waiting_or_gentle, aggressive, final_or_shutdown]`; defaults to
  `default_palette/0`.

  ## Examples

      iex> Severance.Phase.color(:waiting)
      "colour51"

      iex> Severance.Phase.color(:final, ["a", "b", "c"])
      "c"

  """
  @spec color(name(), [String.t()]) :: String.t()
  def color(phase, palette \\ @default_palette) do
    Enum.fetch!(palette, fetch(phase).color_index)
  end

  @doc """
  Returns true when the phase's tmux status should blink.

  ## Examples

      iex> Severance.Phase.blink?(:aggressive)
      true

      iex> Severance.Phase.blink?(:waiting)
      false

  """
  @spec blink?(name()) :: boolean()
  def blink?(phase), do: fetch(phase).blink?

  @doc """
  Returns the default 3-element tmux color palette.
  """
  @spec default_palette() :: [String.t()]
  def default_palette, do: @default_palette

  @spec fetch(name()) :: t()
  defp fetch(phase), do: Map.fetch!(@by_name, phase)
end
