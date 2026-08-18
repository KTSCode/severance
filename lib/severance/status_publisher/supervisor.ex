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

  @doc """
  Rebuilds the worker set from the current `:publishers` application env.

  Terminates and deletes every existing publisher child, then starts one
  per entry in the (possibly changed) config. A removed publisher's
  `:teardown` runs on the way out via `Worker.terminate/2`; a new one runs
  `:teardown` then `:setup` on init — that lifecycle already exists in
  `Worker` and is unchanged here.

  Returns `{:ok, started_count, failed_names}`, where `started_count` counts
  only publishers that actually started and `failed_names` lists the ones
  whose `Supervisor.start_child/2` call errored (e.g. a spec missing `:fn`).
  Returns `{:error, :not_running}` when the supervisor isn't started (e.g.
  test config with `start_children: false`).
  """
  @spec reload() :: {:ok, non_neg_integer(), [atom()]} | {:error, :not_running}
  def reload do
    if Process.whereis(__MODULE__) do
      __MODULE__
      |> Supervisor.which_children()
      |> Enum.each(fn
        {{:publisher, _name} = id, _pid, _type, _modules} ->
          Supervisor.terminate_child(__MODULE__, id)
          Supervisor.delete_child(__MODULE__, id)

        _child ->
          :ok
      end)

      publishers = Application.get_env(:severance, :publishers, %{})

      {started, failed} =
        publishers
        |> Enum.map(fn {name, spec} ->
          {name, Supervisor.start_child(__MODULE__, child_spec_for({name, spec}))}
        end)
        |> Enum.split_with(fn {_name, result} -> match?({:ok, _}, result) or match?({:ok, _, _}, result) end)

      {:ok, length(started), Enum.map(failed, fn {name, _result} -> name end)}
    else
      {:error, :not_running}
    end
  end

  @impl true
  def init(:ok) do
    publishers = Application.get_env(:severance, :publishers, %{})
    workers = Enum.map(publishers, &child_spec_for/1)

    children = [{Registry, keys: :unique, name: Severance.StatusPublisher.Registry} | workers]
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp child_spec_for({name, spec}) do
    Supervisor.child_spec({Severance.StatusPublisher.Worker, {name, spec}}, id: {:publisher, name})
  end
end
