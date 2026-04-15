defmodule Mix.Tasks.Todo do
  @shortdoc "Work on the next README TODO item"

  @moduledoc """
  Picks the next unchecked TODO from README.md, creates a branch, and
  emits an agent prompt. With `--done`, finalizes the work into a PR.

  ## Usage

      mix todo          # start the next TODO item
      mix todo --done   # finalize and open a PR
  """

  use Mix.Task

  @type todo_item :: %{checked: boolean(), text: String.t(), line_number: pos_integer()}

  @doc """
  Parses the `## TODO` section from README content into a list of todo items.

  Returns `{:ok, items}` where each item has `:checked`, `:text`, and
  `:line_number` keys. Returns `{:error, :no_todo_section}` if no
  `## TODO` heading is found.
  """
  @spec parse_todo_section(String.t()) :: {:ok, [todo_item()]} | {:error, :no_todo_section}
  def parse_todo_section(readme) do
    lines = String.split(readme, "\n")

    case Enum.find_index(lines, &(&1 == "## TODO")) do
      nil ->
        {:error, :no_todo_section}

      idx ->
        items =
          lines
          |> Enum.drop(idx + 1)
          |> Enum.with_index(idx + 2)
          |> Enum.take_while(fn {line, _num} -> not next_heading?(line) end)
          |> Enum.flat_map(fn {line, num} -> parse_todo_line(line, num) end)

        {:ok, items}
    end
  end

  @doc """
  Returns the first unchecked item from a list of todo items.

  Returns `{:error, :all_done}` if no unchecked items remain.
  """
  @spec first_unchecked([todo_item()]) :: {:ok, todo_item()} | {:error, :all_done}
  def first_unchecked(items) do
    case Enum.find(items, &(not &1.checked)) do
      nil -> {:error, :all_done}
      item -> {:ok, item}
    end
  end

  @doc """
  Replaces the first `- [ ]` line matching `text` with `- [x]` in the README.

  Only matches lines within the `## TODO` section.
  """
  @spec check_todo_in_readme(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def check_todo_in_readme(readme, text) do
    lines = String.split(readme, "\n")

    case todo_section_range(lines) do
      nil -> {:error, :not_found}
      range -> replace_first_unchecked(lines, text, range)
    end
  end

  @doc """
  Removes the topmost checked TODO items when more than 3 exist.

  Only considers checked items within the `## TODO` section.
  """
  @spec prune_checked_todos(String.t()) :: {:ok, String.t()}
  def prune_checked_todos(readme) do
    lines = String.split(readme, "\n")

    case todo_section_range(lines) do
      nil ->
        {:ok, readme}

      {start_idx, end_idx} ->
        checked_indices =
          lines
          |> Enum.with_index()
          |> Enum.filter(fn {line, idx} ->
            idx >= start_idx and idx <= end_idx and String.starts_with?(line, "- [x] ")
          end)
          |> Enum.map(fn {_line, idx} -> idx end)

        to_remove =
          if length(checked_indices) > 3 do
            Enum.take(checked_indices, length(checked_indices) - 3)
          else
            []
          end

        result =
          lines
          |> Enum.with_index()
          |> Enum.reject(fn {_line, idx} -> idx in to_remove end)
          |> Enum.map_join("\n", fn {line, _idx} -> line end)

        {:ok, result}
    end
  end

  @doc """
  Generates a fresh CHANGELOG.md with the given entry under `### Added`.
  """
  @spec new_changelog(String.t()) :: String.t()
  def new_changelog(entry) do
    """
    # Changelog

    All notable changes to this project will be documented in this file.

    The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

    ## [Unreleased]

    ### Added

    - #{entry}
    """
  end

  @doc """
  Inserts an entry under `## [Unreleased]` / `### Added` in an existing
  CHANGELOG. Creates the sections if missing.
  """
  @spec add_changelog_entry(String.t(), String.t()) :: String.t()
  def add_changelog_entry(changelog, entry) do
    cond do
      has_unreleased_added?(changelog) ->
        insert_under_added(changelog, entry)

      has_unreleased?(changelog) ->
        insert_added_section(changelog, entry)

      true ->
        insert_unreleased_section(changelog, entry)
    end
  end

  @doc """
  Builds the agent prompt emitted by `mix todo` on stdout.

  Includes the TODO item text, full README contents, and TDD workflow
  instructions.
  """
  @spec build_prompt(String.t(), String.t()) :: String.t()
  def build_prompt(todo_text, readme) do
    """
    You are working on the Severance project. Your task is to implement the
    following TODO item:

    > #{todo_text}

    ## Project Context

    #{readme}

    ## Instructions

    1. Create a feature branch from `main` with the `todo/` prefix.
       Choose a concise, descriptive branch name (e.g., `todo/add-user-auth`).
    2. Read AGENTS.md and the codebase to understand conventions and patterns.
    3. Follow TDD: write a failing test first, then implement until it passes.
    4. Commit your changes. Quality checks run automatically on commit.
    5. Run `mix todo --done` to finalize the PR.
    """
  end

  @doc """
  Builds the post-completion prompt emitted by `mix todo --done` on stdout.

  Instructs the agent to update the PR description and review the
  CHANGELOG entry category.
  """
  @spec build_done_prompt(String.t(), String.t()) :: String.t()
  def build_done_prompt(_todo_text, pr_url) do
    """
    TODO item completed. PR created: #{pr_url}

    ## Remaining Steps

    1. Run `git status` to verify all changes were committed. If any files
       are untracked or unstaged, commit and push them.
    2. Update the PR description using `gh pr edit #{pr_url} --body "..."`.
       Follow the convention in AGENTS.md: summary and test plan above the
       fold. If this work was based on an implementation plan, include the
       full plan in a collapsed `<details>` block.
    3. Review CHANGELOG.md — the entry was added under "### Added" as a
       placeholder. Rewrite the entry text to be user-facing (it currently
       contains the raw TODO text). Pick the correct category: Added,
       Changed, Fixed, or Removed. Commit and push any changes.
    """
  end

  @impl Mix.Task
  def run(["--done"]), do: done()
  def run([]), do: start()

  def run(_) do
    Mix.shell().error("Usage: mix todo [--done]")
    exit({:shutdown, 1})
  end

  @doc false
  def start(root \\ File.cwd!()) do
    with :ok <- check_no_current(root),
         :ok <- check_gh_installed(),
         {:ok, readme} <- read_readme(root),
         {:ok, items} <- parse_todo_section(readme),
         {:ok, item} <- first_unchecked(items) do
      :ok = write_current(root, item.text)
      IO.write(build_prompt(item.text, readme))
    else
      error -> handle_error(error)
    end
  end

  @doc false
  def done(root \\ File.cwd!()) do
    with {:ok, todo_text} <- read_current(root),
         :ok <- check_gh_installed(),
         {:ok, readme} <- read_readme(root),
         {:ok, checked_readme} <- check_todo_in_readme(readme, todo_text),
         {:ok, pruned_readme} <- prune_checked_todos(checked_readme),
         :ok <- write_readme(root, pruned_readme),
         :ok <- write_changelog(root, todo_text),
         :ok <- git_commit(todo_text),
         :ok <- git_push(),
         {:ok, pr_url} <- create_pr(todo_text),
         :ok <- delete_current(root) do
      IO.write(build_done_prompt(todo_text, pr_url))
    else
      error -> handle_error(error)
    end
  end

  defp next_heading?("## " <> _), do: true
  defp next_heading?("# " <> _), do: true
  defp next_heading?(_), do: false

  defp todo_section_range(lines) do
    case Enum.find_index(lines, &(&1 == "## TODO")) do
      nil -> nil
      start_idx -> {start_idx, find_section_end(lines, start_idx)}
    end
  end

  defp find_section_end(lines, start_idx) do
    lines
    |> Enum.drop(start_idx + 1)
    |> Enum.with_index(start_idx + 1)
    |> Enum.find_value(length(lines) - 1, fn {line, idx} ->
      if next_heading?(line), do: idx - 1
    end)
  end

  defp replace_first_unchecked(lines, text, {start_idx, end_idx}) do
    {result, replaced} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], false}, fn {line, idx}, {acc, replaced} ->
        in_section = idx >= start_idx and idx <= end_idx

        if not replaced and in_section and String.trim(line) == "- [ ] #{text}" do
          {["- [x] #{text}" | acc], true}
        else
          {[line | acc], replaced}
        end
      end)

    if replaced do
      {:ok, result |> Enum.reverse() |> Enum.join("\n")}
    else
      {:error, :not_found}
    end
  end

  defp parse_todo_line("- [x] " <> text, line_number) do
    [%{checked: true, text: String.trim(text), line_number: line_number}]
  end

  defp parse_todo_line("- [ ] " <> text, line_number) do
    [%{checked: false, text: String.trim(text), line_number: line_number}]
  end

  defp parse_todo_line(_line, _line_number), do: []

  defp has_unreleased_added?(changelog) do
    has_unreleased?(changelog) and
      changelog
      |> unreleased_section()
      |> String.contains?("### Added")
  end

  defp has_unreleased?(changelog) do
    changelog =~ "## [Unreleased]"
  end

  defp unreleased_section(changelog) do
    lines = String.split(changelog, "\n")
    {start_idx, end_idx} = unreleased_range(lines)

    lines
    |> Enum.slice(start_idx..end_idx)
    |> Enum.join("\n")
  end

  defp unreleased_range(lines) do
    start_idx = Enum.find_index(lines, &(&1 == "## [Unreleased]"))

    end_idx =
      lines
      |> Enum.drop(start_idx + 1)
      |> Enum.with_index(start_idx + 1)
      |> Enum.find_value(length(lines) - 1, fn {line, idx} ->
        if String.starts_with?(line, "## [") and line != "## [Unreleased]", do: idx - 1
      end)

    {start_idx, end_idx}
  end

  defp insert_under_added(changelog, entry) do
    lines = String.split(changelog, "\n")
    {unreleased_start, unreleased_end} = unreleased_range(lines)

    added_idx =
      lines
      |> Enum.with_index()
      |> Enum.find_value(fn {line, idx} ->
        if line == "### Added" and idx >= unreleased_start and idx <= unreleased_end, do: idx
      end)

    # Find the last entry line under ### Added, halting at the next heading
    insert_idx =
      lines
      |> Enum.drop(added_idx + 1)
      |> Enum.with_index(added_idx + 1)
      |> Enum.reduce_while(added_idx, fn
        {"### " <> _, _idx}, last -> {:halt, last}
        {"## " <> _, _idx}, last -> {:halt, last}
        {"- " <> _, idx}, _last -> {:cont, idx}
        _, last -> {:cont, last}
      end)

    lines
    |> List.insert_at(insert_idx + 1, "- #{entry}")
    |> Enum.join("\n")
  end

  defp insert_added_section(changelog, entry) do
    lines = String.split(changelog, "\n")
    unreleased_idx = Enum.find_index(lines, &(&1 == "## [Unreleased]"))

    {before, rest} = Enum.split(lines, unreleased_idx + 1)
    added_block = ["", "### Added", "", "- #{entry}"]

    Enum.join(before ++ added_block ++ rest, "\n")
  end

  defp insert_unreleased_section(changelog, entry) do
    lines = String.split(changelog, "\n")

    # Find first version heading to insert before it
    version_idx =
      Enum.find_index(lines, fn line ->
        String.starts_with?(line, "## [") and line != "## [Unreleased]"
      end)

    insert_at = version_idx || length(lines)
    {before, rest} = Enum.split(lines, insert_at)
    unreleased_block = ["## [Unreleased]", "", "### Added", "", "- #{entry}", ""]

    Enum.join(before ++ unreleased_block ++ rest, "\n")
  end

  @doc """
  Extracts a GitHub PR URL from command output that may contain warnings.

  `gh pr create` prints the PR URL as its last line but may include
  warnings on preceding lines when stderr is merged into stdout.
  """
  @spec extract_pr_url(String.t()) :: {:ok, String.t()} | {:error, :no_pr_url}
  def extract_pr_url(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find(&String.starts_with?(&1, "https://"))
    |> case do
      nil -> {:error, :no_pr_url}
      url -> {:ok, String.trim(url)}
    end
  end

  # --- Side-effect helpers ---

  defp cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {output, code}}
    end
  end

  defp check_gh_installed do
    if System.find_executable("gh") do
      :ok
    else
      {:error, :no_gh}
    end
  end

  defp check_no_current(root) do
    path = Path.join(root, ".todo-current")

    if File.exists?(path) do
      text = path |> File.read!() |> String.trim()
      {:error, {:already_started, text}}
    else
      :ok
    end
  end

  defp read_readme(root) do
    path = Path.join(root, "README.md")

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :no_readme}
    end
  end

  defp write_readme(root, content) do
    File.write!(Path.join(root, "README.md"), content)
    :ok
  end

  defp read_current(root) do
    path = Path.join(root, ".todo-current")

    case File.read(path) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, _} -> {:error, :no_current}
    end
  end

  defp write_current(root, text) do
    File.write!(Path.join(root, ".todo-current"), text)
    :ok
  end

  defp delete_current(root) do
    case File.rm(Path.join(root, ".todo-current")) do
      :ok -> :ok
      {:error, reason} -> {:error, {:delete_failed, reason}}
    end
  end

  defp write_changelog(root, todo_text) do
    path = Path.join(root, "CHANGELOG.md")

    content =
      case File.read(path) do
        {:ok, existing} -> add_changelog_entry(existing, todo_text)
        {:error, _} -> new_changelog(todo_text)
      end

    File.write!(path, content)
    :ok
  end

  defp git_commit(todo_text) do
    stderr("Committing changes...")

    with {:ok, _} <- cmd("git", ["add", "README.md", "CHANGELOG.md"]),
         {:ok, _} <- cmd("git", ["commit", "-m", "Complete TODO: #{todo_text}"]) do
      :ok
    end
  end

  defp git_push do
    stderr("Pushing branch...")

    case cmd("git", ["push", "-u", "origin", "HEAD"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp create_pr(todo_text) do
    stderr("Creating pull request...")

    with {:ok, output} <-
           cmd("gh", [
             "pr",
             "create",
             "--title",
             todo_text,
             "--body",
             "Implements: #{todo_text}\n\n_Body to be filled in by the agent._"
           ]) do
      extract_pr_url(output)
    end
  end

  defp handle_error({:error, :no_todo_section}) do
    stderr("No ## TODO section found in README.md")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :all_done}) do
    stderr("All TODO items are checked. Nothing to do!")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :not_found}) do
    stderr("TODO item not found in README.md — may have trailing whitespace or been modified")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_gh}) do
    stderr("gh CLI not found. Install it: https://cli.github.com/")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, {:already_started, text}}) do
    stderr("Already working on: #{text}")
    stderr("Run `mix todo --done` or delete `.todo-current` to reset.")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_readme}) do
    stderr("README.md not found")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_current}) do
    stderr("No .todo-current file found. Run `mix todo` first.")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_pr_url}) do
    stderr("Could not extract PR URL from gh output")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, {:delete_failed, reason}}) do
    stderr("Failed to delete .todo-current: #{reason}")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, {output, code}}) do
    stderr("Command failed (exit #{code}):\n#{output}")
    exit({:shutdown, 1})
  end

  defp stderr(msg) do
    IO.puts(:stderr, msg)
  end
end
