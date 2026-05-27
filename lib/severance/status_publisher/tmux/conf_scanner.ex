defmodule Severance.StatusPublisher.Tmux.ConfScanner do
  @moduledoc """
  Reads `~/.tmux.conf` (or `$TMUX_CONF`) and checks whether a given
  tmux user variable is referenced. Comment lines (leading `#`) are
  stripped before the substring match. No recursion into `source-file`.
  """

  @doc """
  Reads the tmux conf file.

  Returns `{:ok, contents}`, `:missing` when the file does not exist,
  or `{:error, reason}` on read failure.
  """
  @spec read_tmux_conf() :: {:ok, String.t()} | :missing | {:error, term()}
  def read_tmux_conf do
    p = path()

    if File.exists?(p) do
      case File.read(p) do
        {:ok, contents} -> {:ok, contents}
        {:error, reason} -> {:error, reason}
      end
    else
      :missing
    end
  end

  @doc """
  Returns `true` when the tmux conf contents reference `\#{@sev_<var>}`
  on any non-comment line.

  `:missing` and `{:error, _}` always return `false`.
  """
  @spec references?({:ok, String.t()} | :missing | {:error, term()}, String.t()) :: boolean()
  def references?({:ok, contents}, var_name) do
    contents
    |> String.split("\n")
    |> Enum.reject(&comment_line?/1)
    |> Enum.any?(&String.contains?(&1, "\#{@sev_#{var_name}}"))
  end

  def references?(_, _), do: false

  defp comment_line?(line), do: String.starts_with?(String.trim_leading(line), "#")

  defp path do
    case System.get_env("TMUX_CONF") do
      nil -> Path.join(System.user_home!(), ".tmux.conf")
      override -> Path.expand(override)
    end
  end
end
