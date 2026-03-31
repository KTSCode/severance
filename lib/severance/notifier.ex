defmodule Severance.Notifier do
  @moduledoc """
  Builds and sends macOS notifications with escalating urgency
  based on countdown phase.
  """

  @doc """
  Returns the notification sound for a given phase.

  ## Examples

      iex> Severance.Notifier.phase_sound(:gentle)
      "Tink"

      iex> Severance.Notifier.phase_sound(:aggressive)
      "Funk"

      iex> Severance.Notifier.phase_sound(:final)
      "Basso"

      iex> Severance.Notifier.phase_sound(:overtime)
      "Basso"

  """
  @spec phase_sound(:gentle | :aggressive | :final | :overtime) :: String.t()
  def phase_sound(:gentle), do: "Tink"
  def phase_sound(:aggressive), do: "Funk"
  def phase_sound(:final), do: "Basso"
  def phase_sound(:overtime), do: "Basso"

  @doc """
  Returns `{title, body}` for a countdown notification.

  Urgency escalates as minutes remaining decreases. At 1 minute the title
  becomes `"FINAL WARNING"`. At 5 minutes and below the title is uppercased.
  Above 5 minutes the title uses title case.

  ## Examples

      iex> Severance.Notifier.countdown_message(15, :severance)
      {"Shutdown in 15m", "Your computer WILL shut down. Push your work."}

      iex> Severance.Notifier.countdown_message(15, :overtime)
      {"Shutdown in 15m", "Your planned end of day is coming up. Push your work and call it quits."}

      iex> Severance.Notifier.countdown_message(5, :severance)
      {"SHUTDOWN IN 5m", "Your computer WILL shut down. Save everything NOW."}

      iex> Severance.Notifier.countdown_message(1, :severance)
      {"FINAL WARNING", "Your computer shuts down in 1 minute. Save everything."}

  """
  @spec countdown_message(non_neg_integer(), :severance | :overtime) ::
          {String.t(), String.t()}
  def countdown_message(1, :severance) do
    {"FINAL WARNING", "Your computer shuts down in 1 minute. Save everything."}
  end

  def countdown_message(1, :overtime) do
    {"YOU SHOULD BE STOPPING", "1 minute left to decide to be a person and stop."}
  end

  def countdown_message(minutes, mode) when minutes <= 5 do
    body =
      case mode do
        :severance -> "Your computer WILL shut down. Save everything NOW."
        :overtime -> "You said you would stop NOW."
      end

    {"SHUTDOWN IN #{minutes}m", body}
  end

  def countdown_message(minutes, mode) do
    body =
      case mode do
        :severance -> "Your computer WILL shut down. Push your work."
        :overtime -> "Your planned end of day is coming up. Push your work and call it quits."
      end

    {"Shutdown in #{minutes}m", body}
  end

  @doc """
  Sends a countdown notification for the given minutes, mode, and phase.

  Delegates to the configured system adapter.
  """
  @spec send_countdown(non_neg_integer(), :severance | :overtime, :gentle | :aggressive | :final) ::
          :ok
  def send_countdown(minutes, mode, phase) do
    {title, body} = countdown_message(minutes, mode)
    sound = phase_sound(phase)
    system().notify(title, body, sound)
  end

  @doc """
  Sends a notification about a stale tmux pane.

  Delegates to the configured system adapter.
  """
  @spec send_stale_pane(%{pane: String.t(), path: String.t()}) :: :ok
  def send_stale_pane(%{pane: pane, path: path}) do
    system().notify(
      "Stale pane: #{pane}",
      "No activity in 15m. Save your work and leave a note so you can pick up where you left off.\n#{path}",
      "Tink"
    )
  end

  @doc """
  Sends the overtime burst notification used every 5 seconds.

  Delegates to the configured system adapter.
  """
  @spec send_overtime_burst() :: :ok
  def send_overtime_burst do
    system().notify(
      "QUITTING TIME!",
      "You said you'd stop working. Go be a person.",
      "Basso"
    )
  end

  defp system, do: Severance.System.adapter()
end
