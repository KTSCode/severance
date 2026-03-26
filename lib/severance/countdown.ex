defmodule Severance.Countdown do
  @moduledoc """
  GenServer managing the deep work countdown timer.

  Tracks time remaining until shutdown, emits notifications at escalating
  intervals, and triggers machine shutdown when the timer expires.
  """

  use GenServer

  @doc """
  Starts the Countdown GenServer linked to the supervision tree.

  Accepts `shutdown_time: ~T[16:30:00]` in opts.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end
end
