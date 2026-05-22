defmodule Severance.StatusPublisher.Supervisor do
  @moduledoc """
  Supervises one `Severance.StatusPublisher.Worker` per publisher
  entry in `Application.get_env(:severance, :publishers, %{})`.

  A `Registry` is started as the first child so workers can register
  by name regardless of publisher count.
  """

  use Supervisor

  @doc """
  Starts the publisher supervisor.
  """
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    publishers = Application.get_env(:severance, :publishers, %{})

    workers =
      Enum.map(publishers, fn {name, spec} ->
        Supervisor.child_spec(
          {Severance.StatusPublisher.Worker, {name, spec}},
          id: {:publisher, name}
        )
      end)

    children = [{Registry, keys: :unique, name: Severance.StatusPublisher.Registry} | workers]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
