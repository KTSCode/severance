defmodule Severance.Timezone do
  @moduledoc """
  Infers the system IANA timezone from `/etc/localtime`.

  On macOS (and most Linux systems), `/etc/localtime` is a symlink pointing
  into the zoneinfo directory. This module reads that symlink and extracts
  the IANA timezone identifier (e.g. `"America/Los_Angeles"`).
  """

  @localtime_path "/etc/localtime"

  @doc """
  Infers the system timezone from the `/etc/localtime` symlink.

  Returns `{:ok, timezone}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> {:ok, tz} = Severance.Timezone.infer()
      iex> is_binary(tz) and String.contains?(tz, "/")
      true
  """
  @spec infer() :: {:ok, String.t()} | {:error, :not_a_symlink | :unrecognized_path}
  def infer do
    case File.read_link(@localtime_path) do
      {:ok, target} -> infer_from_localtime(target)
      {:error, _} -> {:error, :not_a_symlink}
    end
  end

  @doc """
  Extracts the IANA timezone identifier from a zoneinfo path.

  Looks for `zoneinfo/` in the path and returns everything after it.

  ## Examples

      iex> Severance.Timezone.infer_from_localtime("/var/db/timezone/zoneinfo/America/Los_Angeles")
      {:ok, "America/Los_Angeles"}

      iex> Severance.Timezone.infer_from_localtime("/usr/share/zoneinfo/Europe/London")
      {:ok, "Europe/London"}
  """
  @spec infer_from_localtime(String.t()) :: {:ok, String.t()} | {:error, :unrecognized_path}
  def infer_from_localtime(path) do
    case String.split(path, "zoneinfo/", parts: 2) do
      [_, tz] when tz != "" -> {:ok, tz}
      _ -> {:error, :unrecognized_path}
    end
  end
end
