defmodule Mix.Tasks.Changelog.Finalize do
  @shortdoc "Finalize the changelog for an upcoming release"

  @moduledoc """
  Moves entries from `## [Unreleased]` into a versioned section,
  then commits `CHANGELOG.md`.

  Accepts a bump flag that matches `mix version` so both tasks can share
  the same args when called from the `mix tag` alias:

      mix changelog.finalize --major
      mix changelog.finalize --minor
      mix changelog.finalize --patch
  """

  use Mix.Task

  @doc """
  Parses the bump flag from args list.

  ## Examples

      iex> Mix.Tasks.Changelog.Finalize.parse_bump_flag(["--major"])
      {:ok, :major}

      iex> Mix.Tasks.Changelog.Finalize.parse_bump_flag(["--patch"])
      {:ok, :patch}

      iex> Mix.Tasks.Changelog.Finalize.parse_bump_flag([])
      {:error, :invalid_flag}
  """
  @spec parse_bump_flag([String.t()]) :: {:ok, :major | :minor | :patch} | {:error, :invalid_flag}
  def parse_bump_flag(args) do
    cond do
      "--major" in args -> {:ok, :major}
      "--minor" in args -> {:ok, :minor}
      "--patch" in args -> {:ok, :patch}
      true -> {:error, :invalid_flag}
    end
  end

  @doc """
  Computes a new version string by bumping the specified component.

  ## Examples

      iex> Mix.Tasks.Changelog.Finalize.bump_version("0.1.0", :major)
      {:ok, "1.0.0"}

      iex> Mix.Tasks.Changelog.Finalize.bump_version("0.1.0", :minor)
      {:ok, "0.2.0"}

      iex> Mix.Tasks.Changelog.Finalize.bump_version("0.1.0", :patch)
      {:ok, "0.1.1"}
  """
  @spec bump_version(String.t(), :major | :minor | :patch) ::
          {:ok, String.t()} | {:error, :invalid_version}
  def bump_version(version, component) do
    case Version.parse(version) do
      {:ok, %Version{major: maj, minor: min, patch: pat}} ->
        {:ok, do_bump(maj, min, pat, component)}

      :error ->
        {:error, :invalid_version}
    end
  end

  @doc """
  Extracts the content under `## [Unreleased]` up to the next version heading.

  Returns `{:error, :empty_unreleased}` if the section has no list entries,
  and `{:error, :no_unreleased}` if the section is missing entirely.
  """
  @spec unreleased_entries(String.t()) ::
          {:ok, String.t()} | {:error, :empty_unreleased | :no_unreleased}
  def unreleased_entries(changelog) do
    lines = String.split(changelog, "\n")

    case Enum.find_index(lines, &(&1 == "## [Unreleased]")) do
      nil ->
        {:error, :no_unreleased}

      idx ->
        entries =
          lines
          |> Enum.drop(idx + 1)
          |> Enum.take_while(fn line ->
            not (String.starts_with?(line, "## [") and line != "## [Unreleased]")
          end)
          |> Enum.join("\n")
          |> String.trim()

        has_list_items =
          entries |> String.split("\n") |> Enum.any?(&String.starts_with?(&1, "- "))

        if has_list_items do
          {:ok, entries}
        else
          {:error, :empty_unreleased}
        end
    end
  end

  @doc """
  Moves entries from `## [Unreleased]` under a new versioned heading and
  adds a fresh empty `## [Unreleased]` section at the top.
  """
  @spec finalize_changelog(String.t(), String.t(), String.t()) :: String.t()
  def finalize_changelog(changelog, version, date) do
    lines = String.split(changelog, "\n")
    unreleased_idx = Enum.find_index(lines, &(&1 == "## [Unreleased]"))

    {before_unreleased, from_unreleased} = Enum.split(lines, unreleased_idx)

    [_unreleased_heading | after_heading] = from_unreleased

    {entries, rest} =
      Enum.split_while(after_heading, fn line ->
        not (String.starts_with?(line, "## [") and line != "## [Unreleased]")
      end)

    new_lines =
      before_unreleased ++
        ["## [Unreleased]", ""] ++
        ["## [#{version}] -- #{date}"] ++
        entries ++
        rest

    Enum.join(new_lines, "\n")
  end

  @impl Mix.Task
  def run(args) do
    with {:ok, component} <- parse_bump_flag(args),
         {:ok, current} <- read_version(),
         {:ok, new_version} <- bump_version(current, component),
         {:ok, changelog} <- read_changelog(),
         {:ok, _entries} <- unreleased_entries(changelog),
         :ok <- confirm_release(changelog, current, new_version),
         finalized = finalize_changelog(changelog, new_version, today()),
         :ok <- write_changelog(finalized),
         :ok <- git_commit(new_version) do
      :ok
    else
      {:error, :aborted} ->
        stderr("Aborted.")
        exit({:shutdown, 1})

      {:error, reason} ->
        handle_error(reason)
    end
  end

  # --- Private helpers ---

  defp do_bump(maj, _min, _pat, :major), do: "#{maj + 1}.0.0"
  defp do_bump(maj, min, _pat, :minor), do: "#{maj}.#{min + 1}.0"
  defp do_bump(maj, min, pat, :patch), do: "#{maj}.#{min}.#{pat + 1}"

  defp read_version do
    {:ok, Mix.Project.config()[:version]}
  end

  defp read_changelog do
    case File.read("CHANGELOG.md") do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :no_changelog}
    end
  end

  defp write_changelog(content) do
    File.write!("CHANGELOG.md", content)
    :ok
  end

  defp today do
    {{year, month, day}, _time} = :calendar.local_time()
    year |> Date.new!(month, day) |> Date.to_iso8601()
  end

  defp confirm_release(changelog, current, new_version) do
    {:ok, entries} = unreleased_entries(changelog)

    stderr("\n--- Changelog for v#{new_version} (was v#{current}) ---\n")
    stderr(entries)
    stderr("\n---\n")
    stderr("")

    IO.write(:stderr, "Proceed? [y/N] ")

    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        if String.trim(line) in ["y", "Y"], do: :ok, else: {:error, :aborted}

      _ ->
        {:error, :aborted}
    end
  end

  defp git_commit(version) do
    stderr("Committing changelog...")

    with {:ok, _} <- cmd("git", ["add", "CHANGELOG.md"]),
         {:ok, _} <- cmd("git", ["commit", "-m", "Finalize changelog for #{version}"]) do
      :ok
    end
  end

  defp cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {output, code}}
    end
  end

  defp handle_error(reason) do
    stderr(error_message(reason))
    exit({:shutdown, 1})
  end

  defp error_message(:invalid_flag), do: "Usage: mix changelog.finalize <--major|--minor|--patch>"
  defp error_message(:invalid_version), do: "Could not parse current version from mix.exs"
  defp error_message(:empty_unreleased), do: "No entries in [Unreleased] section. Nothing to release."
  defp error_message(:no_unreleased), do: "No [Unreleased] section found in CHANGELOG.md"
  defp error_message(:no_changelog), do: "CHANGELOG.md not found"
  defp error_message({output, code}) when is_binary(output), do: "Command failed (exit #{code}):\n#{output}"
  defp error_message(reason), do: "Unexpected error: #{inspect(reason)}"

  defp stderr(msg), do: IO.puts(:stderr, msg)
end
