defmodule Mix.Tasks.Tag do
  @moduledoc """
  Bumps the application version, finalizes the changelog, and pushes a
  git tag to trigger the CI release workflow.

  ## Usage

      mix tag maj   # bump major version
      mix tag min   # bump minor version
      mix tag pat   # bump patch version
  """

  use Mix.Task

  @shortdoc "Tag a new release version"

  @doc """
  Computes a new version string by bumping the specified component.

  ## Examples

      iex> Mix.Tasks.Tag.bump_version("0.1.0", :maj)
      {:ok, "1.0.0"}

      iex> Mix.Tasks.Tag.bump_version("0.1.0", :min)
      {:ok, "0.2.0"}

      iex> Mix.Tasks.Tag.bump_version("0.1.0", :pat)
      {:ok, "0.1.1"}
  """
  @spec bump_version(String.t(), :maj | :min | :pat) ::
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
  Replaces the version string in mix.exs file content.

  Matches the pattern `version: "X.Y.Z"` and replaces the version.
  """
  @spec update_version_in_mix(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :version_not_found}
  def update_version_in_mix(content, new_version) do
    pattern = ~r/(version:\s*")([^"]+)(")/

    if Regex.match?(pattern, content) do
      {:ok, Regex.replace(pattern, content, "\\g{1}#{new_version}\\g{3}", global: false)}
    else
      {:error, :version_not_found}
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

  @doc """
  Parses a version component string into an atom.

  ## Examples

      iex> Mix.Tasks.Tag.parse_component("maj")
      {:ok, :maj}

      iex> Mix.Tasks.Tag.parse_component("invalid")
      {:error, :invalid_component}
  """
  @spec parse_component(String.t()) :: {:ok, :maj | :min | :pat} | {:error, :invalid_component}
  def parse_component("maj"), do: {:ok, :maj}
  def parse_component("min"), do: {:ok, :min}
  def parse_component("pat"), do: {:ok, :pat}
  def parse_component(_), do: {:error, :invalid_component}

  @impl Mix.Task
  def run([arg]) do
    with {:ok, component} <- parse_component(arg),
         :ok <- check_main_branch(),
         :ok <- check_clean_worktree(),
         {:ok, current} <- read_version(),
         {:ok, new_version} <- bump_version(current, component),
         {:ok, changelog} <- read_changelog(),
         {:ok, _entries} <- unreleased_entries(changelog),
         :ok <- confirm_release(changelog, current, new_version),
         finalized <- finalize_changelog(changelog, new_version, today()),
         {:ok, mix_content} <- read_mix_exs(),
         {:ok, new_mix} <- update_version_in_mix(mix_content, new_version),
         :ok <- write_mix_exs(new_mix),
         :ok <- write_changelog(finalized),
         :ok <- git_commit(new_version),
         :ok <- git_tag(new_version),
         :ok <- git_push(new_version) do
      stderr("Tagged v#{new_version} and pushed. CI will handle the release.")
    else
      {:error, :aborted} ->
        stderr("Aborted.")

      {:error, reason} ->
        handle_error(reason)
    end
  end

  def run(_) do
    stderr("Usage: mix tag <maj|min|pat>")
    exit({:shutdown, 1})
  end

  # --- Private helpers ---

  defp do_bump(maj, _min, _pat, :maj), do: "#{maj + 1}.0.0"
  defp do_bump(maj, min, _pat, :min), do: "#{maj}.#{min + 1}.0"
  defp do_bump(maj, min, pat, :pat), do: "#{maj}.#{min}.#{pat + 1}"

  defp cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {output, code}}
    end
  end

  defp check_main_branch do
    case cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, "main"} -> :ok
      {:ok, branch} -> {:error, {:not_main, branch}}
      error -> error
    end
  end

  defp check_clean_worktree do
    case cmd("git", ["status", "--porcelain"]) do
      {:ok, ""} -> :ok
      {:ok, _} -> {:error, :dirty_worktree}
      error -> error
    end
  end

  defp read_version do
    {:ok, Mix.Project.config()[:version]}
  end

  defp read_changelog do
    case File.read("CHANGELOG.md") do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :no_changelog}
    end
  end

  defp read_mix_exs do
    case File.read("mix.exs") do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :no_mix_exs}
    end
  end

  defp write_mix_exs(content) do
    File.write!("mix.exs", content)
    :ok
  end

  defp write_changelog(content) do
    File.write!("CHANGELOG.md", content)
    :ok
  end

  defp today do
    Date.utc_today() |> Date.to_iso8601()
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
    stderr("Committing...")

    with {:ok, _} <- cmd("git", ["add", "mix.exs", "CHANGELOG.md"]),
         {:ok, _} <- cmd("git", ["commit", "-m", "Release v#{version}"]) do
      :ok
    end
  end

  defp git_tag(version) do
    stderr("Tagging v#{version}...")
    cmd("git", ["tag", "v#{version}"]) |> normalize()
  end

  defp git_push(version) do
    stderr("Pushing...")
    cmd("git", ["push", "--atomic", "origin", "HEAD", "v#{version}"]) |> normalize()
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize(error), do: error

  defp handle_error(reason) do
    stderr(error_message(reason))
    exit({:shutdown, 1})
  end

  defp error_message({:not_main, branch}),
    do: "Must be on main branch to tag a release (currently on #{branch})"

  defp error_message(:dirty_worktree),
    do: "Uncommitted changes detected. Commit or stash them before tagging."

  defp error_message(:invalid_component), do: "Usage: mix tag <maj|min|pat>"
  defp error_message(:invalid_version), do: "Could not parse current version from mix.exs"

  defp error_message(:empty_unreleased),
    do: "No entries in [Unreleased] section. Nothing to release."

  defp error_message(:no_unreleased), do: "No [Unreleased] section found in CHANGELOG.md"
  defp error_message(:no_changelog), do: "CHANGELOG.md not found"
  defp error_message(:no_mix_exs), do: "mix.exs not found"
  defp error_message(:version_not_found), do: "Could not find version field in mix.exs"

  defp error_message({output, code}) when is_binary(output),
    do: "Command failed (exit #{code}):\n#{output}"

  defp error_message(reason), do: "Unexpected error: #{inspect(reason)}"

  defp stderr(msg), do: IO.puts(:stderr, msg)
end
