defmodule Severance.Application do
  @moduledoc """
  OTP Application entry point. Starts the supervision tree with
  the Countdown GenServer.
  """

  use Application

  @impl true
  def start(_type, _args) do
    shutdown_time = Application.get_env(:severance, :shutdown_time, ~T[16:30:00])

    children = [
      {Severance.Countdown, shutdown_time: shutdown_time}
    ]

    opts = [strategy: :one_for_one, name: Severance.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
