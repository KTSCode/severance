defmodule Severance.StatusPublisher.Tmux do
  @moduledoc """
  Helpers for building tmux-targeted publishers. A publisher writes
  the formatted status string to a tmux user variable (`@sev_<var>`);
  the user's `~/.tmux.conf` references that variable from
  `status-right` (or wherever).

  See `Severance.StatusPublisher` for the publisher contract.
  """

  @default_interval 60_000

  @doc """
  Builds a publisher map that writes `formatter.(status)` to the tmux
  user variable `@sev_<var_name>` on each tick.

  Returns a map with `:fn`, `:teardown`, `:tmux_var`, `:interval_ms`.

  ## Examples

      iex> spec = Severance.StatusPublisher.Tmux.publisher("countdown", fn _ -> "x" end)
      iex> spec.tmux_var
      "countdown"
      iex> spec.interval_ms
      60000
  """
  @spec publisher(String.t(), (Severance.Status.t() -> String.t()), keyword()) :: map()
  def publisher(var_name, formatter, opts \\ []) when is_binary(var_name) and is_function(formatter, 1) do
    %{
      fn: fn status -> set_var(var_name, formatter.(status)) end,
      teardown: fn -> clear_var(var_name) end,
      tmux_var: var_name,
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval)
    }
  end

  @doc """
  Writes the given value to the tmux user variable `@sev_<var>` via
  the configured system adapter.
  """
  @spec set_var(String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def set_var(var, value) do
    Severance.System.adapter().tmux_cmd(["set", "-gq", "@sev_#{var}", value])
  end

  @doc """
  Clears the tmux user variable `@sev_<var>` by setting it to the
  empty string.
  """
  @spec clear_var(String.t()) :: {String.t(), non_neg_integer()}
  def clear_var(var) do
    Severance.System.adapter().tmux_cmd(["set", "-gq", "@sev_#{var}", ""])
  end
end
