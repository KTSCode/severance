# `mix tag` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A mix task that bumps the version, finalizes the changelog, commits, tags, and pushes to trigger the CI release workflow.

**Architecture:** Single Mix task module (`Mix.Tasks.Tag`) following the same patterns as the existing `Mix.Tasks.Todo` — pure functions are public and tested, side effects are private. The task guards against running from non-main branches and empty unreleased sections.

**Tech Stack:** Elixir Mix task, git CLI, Keep a Changelog format

---

## File Structure

- Create: `lib/mix/tasks/tag.ex` — the mix task module
- Create: `test/mix/tasks/tag_test.exs` — tests for all pure functions
- Modify: `mix.exs:5` — version string (modified at runtime by the task, not by us)
- Modify: `CHANGELOG.md` — changelog (modified at runtime by the task, not by us)

---

### Task 1: Version Bumping

**Files:**
- Create: `test/mix/tasks/tag_test.exs`
- Create: `lib/mix/tasks/tag.ex`

- [ ] **Step 1: Write failing tests for `bump_version/2`**

```elixir
# test/mix/tasks/tag_test.exs
defmodule Mix.Tasks.TagTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Tag

  describe "bump_version/2" do
    test "bumps major version" do
      assert {:ok, "1.0.0"} = Tag.bump_version("0.1.0", :maj)
    end

    test "bumps minor version" do
      assert {:ok, "0.2.0"} = Tag.bump_version("0.1.0", :min)
    end

    test "bumps patch version" do
      assert {:ok, "0.1.1"} = Tag.bump_version("0.1.0", :pat)
    end

    test "major resets minor and patch" do
      assert {:ok, "2.0.0"} = Tag.bump_version("1.3.5", :maj)
    end

    test "minor resets patch" do
      assert {:ok, "1.4.0"} = Tag.bump_version("1.3.5", :min)
    end

    test "returns error for invalid version" do
      assert {:error, :invalid_version} = Tag.bump_version("not.a.version", :min)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: Compilation error — `Mix.Tasks.Tag` does not exist.

- [ ] **Step 3: Implement `bump_version/2`**

```elixir
# lib/mix/tasks/tag.ex
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

  defp do_bump(maj, _min, _pat, :maj), do: "#{maj + 1}.0.0"
  defp do_bump(maj, min, _pat, :min), do: "#{maj}.#{min + 1}.0"
  defp do_bump(maj, min, pat, :pat), do: "#{maj}.#{min}.#{pat + 1}"
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: 6 tests, 0 failures

- [ ] **Step 5: Run format and credo**

Run: `mix format lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs`
Run: `mix credo --strict lib/mix/tasks/tag.ex`

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs
git commit -m "Add bump_version/2 for mix tag"
```

---

### Task 2: Version String Replacement in mix.exs

**Files:**
- Modify: `test/mix/tasks/tag_test.exs`
- Modify: `lib/mix/tasks/tag.ex`

- [ ] **Step 1: Write failing tests for `update_version_in_mix/2`**

Add to `tag_test.exs`:

```elixir
describe "update_version_in_mix/2" do
  test "replaces version string in mix.exs content" do
    mix_content = ~S|version: "0.1.0",|
    assert {:ok, result} = Tag.update_version_in_mix(mix_content, "0.2.0")
    assert result =~ ~S|version: "0.2.0"|
  end

  test "only replaces in version field, not elsewhere" do
    mix_content = """
    version: "0.1.0",
    elixir: "~> 1.19",
    """

    assert {:ok, result} = Tag.update_version_in_mix(mix_content, "0.2.0")
    assert result =~ ~S|version: "0.2.0"|
    assert result =~ ~S|elixir: "~> 1.19"|
  end

  test "returns error when version field not found" do
    assert {:error, :version_not_found} = Tag.update_version_in_mix("no version here", "1.0.0")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: 3 new failures — `update_version_in_mix/2` undefined.

- [ ] **Step 3: Implement `update_version_in_mix/2`**

Add to `lib/mix/tasks/tag.ex`:

```elixir
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: 9 tests, 0 failures

- [ ] **Step 5: Run format and credo**

Run: `mix format lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs`
Run: `mix credo --strict lib/mix/tasks/tag.ex`

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs
git commit -m "Add update_version_in_mix/2"
```

---

### Task 3: Changelog Finalization

**Files:**
- Modify: `test/mix/tasks/tag_test.exs`
- Modify: `lib/mix/tasks/tag.ex`

- [ ] **Step 1: Write failing tests for `unreleased_entries/1`**

Add to `tag_test.exs`:

```elixir
describe "unreleased_entries/1" do
  test "extracts entries under Unreleased section" do
    changelog = """
    # Changelog

    ## [Unreleased]

    ### Added

    - Feature one
    - Feature two

    ### Fixed

    - Bug fix one

    ## [0.1.0] -- 2026-03-29

    ### Added

    - Initial release
    """

    assert {:ok, entries} = Tag.unreleased_entries(changelog)
    assert entries =~ "### Added"
    assert entries =~ "- Feature one"
    assert entries =~ "- Bug fix one"
    refute entries =~ "Initial release"
  end

  test "returns error when unreleased section is empty" do
    changelog = """
    # Changelog

    ## [Unreleased]

    ## [0.1.0] -- 2026-03-29

    ### Added

    - Initial release
    """

    assert {:error, :empty_unreleased} = Tag.unreleased_entries(changelog)
  end

  test "returns error when no unreleased section exists" do
    changelog = """
    # Changelog

    ## [0.1.0] -- 2026-03-29

    ### Added

    - Initial release
    """

    assert {:error, :no_unreleased} = Tag.unreleased_entries(changelog)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: 3 new failures — `unreleased_entries/1` undefined.

- [ ] **Step 3: Implement `unreleased_entries/1`**

Add to `lib/mix/tasks/tag.ex`:

```elixir
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

      if entries == "" do
        {:error, :empty_unreleased}
      else
        {:ok, entries}
      end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: 12 tests, 0 failures

- [ ] **Step 5: Run format and credo**

Run: `mix format lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs`
Run: `mix credo --strict lib/mix/tasks/tag.ex`

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs
git commit -m "Add unreleased_entries/1"
```

---

### Task 4: Changelog Finalization (finalize_changelog/3)

**Files:**
- Modify: `test/mix/tasks/tag_test.exs`
- Modify: `lib/mix/tasks/tag.ex`

- [ ] **Step 1: Write failing tests for `finalize_changelog/3`**

Add to `tag_test.exs`:

```elixir
describe "finalize_changelog/3" do
  test "moves unreleased entries under versioned heading" do
    changelog = """
    # Changelog

    ## [Unreleased]

    ### Added

    - Feature one

    ## [0.1.0] -- 2026-03-29

    ### Added

    - Initial release
    """

    result = Tag.finalize_changelog(changelog, "0.2.0", "2026-04-01")
    assert result =~ "## [Unreleased]"
    assert result =~ "## [0.2.0] -- 2026-04-01"
    assert result =~ "- Feature one"
    assert result =~ "## [0.1.0] -- 2026-03-29"
  end

  test "new unreleased section is empty" do
    changelog = """
    # Changelog

    ## [Unreleased]

    ### Added

    - Feature one

    ## [0.1.0] -- 2026-03-29
    """

    result = Tag.finalize_changelog(changelog, "0.2.0", "2026-04-01")
    lines = String.split(result, "\n")
    unreleased_idx = Enum.find_index(lines, &(&1 == "## [Unreleased]"))
    version_idx = Enum.find_index(lines, &(&1 =~ "## [0.2.0]"))

    # Nothing but whitespace between unreleased and new version heading
    between =
      lines
      |> Enum.slice((unreleased_idx + 1)..(version_idx - 1))
      |> Enum.join("")
      |> String.trim()

    assert between == ""
  end

  test "preserves multiple subsections in unreleased" do
    changelog = """
    # Changelog

    ## [Unreleased]

    ### Added

    - New thing

    ### Fixed

    - Bug fix

    ## [0.1.0] -- 2026-03-29
    """

    result = Tag.finalize_changelog(changelog, "0.2.0", "2026-04-01")
    assert result =~ "## [0.2.0] -- 2026-04-01"
    assert result =~ "### Added\n\n- New thing"
    assert result =~ "### Fixed\n\n- Bug fix"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: 3 new failures — `finalize_changelog/3` undefined.

- [ ] **Step 3: Implement `finalize_changelog/3`**

Add to `lib/mix/tasks/tag.ex`:

```elixir
@doc """
Moves entries from `## [Unreleased]` under a new versioned heading and
adds a fresh empty `## [Unreleased]` section at the top.
"""
@spec finalize_changelog(String.t(), String.t(), String.t()) :: String.t()
def finalize_changelog(changelog, version, date) do
  lines = String.split(changelog, "\n")
  unreleased_idx = Enum.find_index(lines, &(&1 == "## [Unreleased]"))

  {before_unreleased, from_unreleased} = Enum.split(lines, unreleased_idx)

  # Split at the next version heading after [Unreleased]
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: 15 tests, 0 failures

- [ ] **Step 5: Run format and credo**

Run: `mix format lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs`
Run: `mix credo --strict lib/mix/tasks/tag.ex`

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs
git commit -m "Add finalize_changelog/3"
```

---

### Task 5: Parse Args and Branch Guard

**Files:**
- Modify: `test/mix/tasks/tag_test.exs`
- Modify: `lib/mix/tasks/tag.ex`

- [ ] **Step 1: Write failing tests for `parse_component/1`**

Add to `tag_test.exs`:

```elixir
describe "parse_component/1" do
  test "parses maj" do
    assert {:ok, :maj} = Tag.parse_component("maj")
  end

  test "parses min" do
    assert {:ok, :min} = Tag.parse_component("min")
  end

  test "parses pat" do
    assert {:ok, :pat} = Tag.parse_component("pat")
  end

  test "returns error for unknown component" do
    assert {:error, :invalid_component} = Tag.parse_component("major")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: 4 new failures — `parse_component/1` undefined.

- [ ] **Step 3: Implement `parse_component/1`**

Add to `lib/mix/tasks/tag.ex`:

```elixir
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/mix/tasks/tag_test.exs`
Expected: 19 tests, 0 failures

- [ ] **Step 5: Run format and credo**

Run: `mix format lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs`
Run: `mix credo --strict lib/mix/tasks/tag.ex`

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/tag.ex test/mix/tasks/tag_test.exs
git commit -m "Add parse_component/1"
```

---

### Task 6: Wire Up run/1 and Side Effects

**Files:**
- Modify: `lib/mix/tasks/tag.ex`

This task wires the pure functions together with side-effect helpers (git commands, file I/O, user prompt). No new tests for the side-effect wiring — the pure functions are already tested.

- [ ] **Step 1: Add side-effect helpers and `run/1`**

Add private helpers and the `run/1` callback to `lib/mix/tasks/tag.ex`:

```elixir
@impl Mix.Task
def run([arg]) do
  with {:ok, component} <- parse_component(arg),
       :ok <- check_main_branch(),
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
       :ok <- git_push() do
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

# --- Side-effect helpers ---

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

defp git_push do
  stderr("Pushing...")

  with {:ok, _} <- cmd("git", ["push"]),
       {:ok, _} <- cmd("git", ["push", "--tags"]) do
    :ok
  end
end

defp normalize({:ok, _}), do: :ok
defp normalize(error), do: error

defp handle_error({:not_main, branch}) do
  stderr("Must be on main branch to tag a release (currently on #{branch})")
  exit({:shutdown, 1})
end

defp handle_error(:invalid_component) do
  stderr("Usage: mix tag <maj|min|pat>")
  exit({:shutdown, 1})
end

defp handle_error(:invalid_version) do
  stderr("Could not parse current version from mix.exs")
  exit({:shutdown, 1})
end

defp handle_error(:empty_unreleased) do
  stderr("No entries in [Unreleased] section. Nothing to release.")
  exit({:shutdown, 1})
end

defp handle_error(:no_unreleased) do
  stderr("No [Unreleased] section found in CHANGELOG.md")
  exit({:shutdown, 1})
end

defp handle_error(:no_changelog) do
  stderr("CHANGELOG.md not found")
  exit({:shutdown, 1})
end

defp handle_error(:no_mix_exs) do
  stderr("mix.exs not found")
  exit({:shutdown, 1})
end

defp handle_error(:version_not_found) do
  stderr("Could not find version field in mix.exs")
  exit({:shutdown, 1})
end

defp handle_error({output, code}) when is_binary(output) do
  stderr("Command failed (exit #{code}):\n#{output}")
  exit({:shutdown, 1})
end

defp handle_error(reason) do
  stderr("Unexpected error: #{inspect(reason)}")
  exit({:shutdown, 1})
end

defp stderr(msg), do: IO.puts(:stderr, msg)
```

- [ ] **Step 2: Run full test suite**

Run: `mix test`
Expected: All tests pass (existing + new).

- [ ] **Step 3: Run format and credo**

Run: `mix format lib/mix/tasks/tag.ex`
Run: `mix credo --strict lib/mix/tasks/tag.ex`

- [ ] **Step 4: Commit**

```bash
git add lib/mix/tasks/tag.ex
git commit -m "Wire up mix tag run/1 with side effects"
```

---

### Task 7: Manual Smoke Test

No code changes — verify the task works end-to-end on a throwaway branch before using it for real.

- [ ] **Step 1: Verify branch guard**

Run: `git checkout -b test/mix-tag-smoke`
Run: `mix tag min`
Expected: Error message about not being on main branch.

- [ ] **Step 2: Clean up**

Run: `git checkout main`
Run: `git branch -D test/mix-tag-smoke`

- [ ] **Step 3: Verify arg validation**

Run: `mix tag`
Expected: Usage message.

Run: `mix tag major`
Expected: Usage message.

- [ ] **Step 4: Verify empty unreleased guard**

Temporarily empty the `[Unreleased]` section in CHANGELOG.md, then:
Run: `mix tag pat`
Expected: Error about no entries in unreleased section. Restore CHANGELOG.md afterward.
