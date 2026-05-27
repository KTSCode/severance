defmodule Severance.Status do
  @moduledoc """
  Snapshot of daemon state passed to user-defined publishers and
  rendered by `sev status`. Returned by `Severance.Countdown.status/0`.
  """

  @type phase :: :waiting | :gentle | :aggressive | :final | :shutdown | :done
  @type mode :: :severance | :overtime

  @type t :: %__MODULE__{
          mode: mode(),
          phase: phase(),
          shutdown_time: Time.t() | nil,
          minutes_remaining: integer() | nil,
          seconds_remaining: integer() | nil,
          version: String.t() | nil,
          update_available?: boolean() | nil,
          log_path: String.t() | nil
        }

  defstruct [
    :mode,
    :phase,
    :shutdown_time,
    :minutes_remaining,
    :seconds_remaining,
    :version,
    :update_available?,
    :log_path
  ]
end
