defmodule Mix.Tasks.TodoTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Todo

  describe "parse_todo_section/1" do
    test "parses mixed checked and unchecked items" do
      readme = """
      # Project

      ## TODO
      - [x] First done item
      - [ ] Second pending item
      - [x] Third done item
      - [ ] Fourth pending item
      """

      assert {:ok, items} = Todo.parse_todo_section(readme)
      assert length(items) == 4

      assert [
               %{checked: true, text: "First done item", line_number: 4},
               %{checked: false, text: "Second pending item", line_number: 5},
               %{checked: true, text: "Third done item", line_number: 6},
               %{checked: false, text: "Fourth pending item", line_number: 7}
             ] = items
    end

    test "returns error when no TODO section exists" do
      readme = """
      # Project

      ## Installation
      - Run mix deps.get
      """

      assert {:error, :no_todo_section} = Todo.parse_todo_section(readme)
    end

    test "returns ok with empty list when TODO section has no items" do
      readme = """
      # Project

      ## TODO

      ## Other Section
      """

      assert {:ok, []} = Todo.parse_todo_section(readme)
    end

    test "stops at next heading" do
      readme = """
      # Project

      ## TODO
      - [ ] Only item

      ## Roadmap
      - [ ] This is not a TODO item
      """

      assert {:ok, [item]} = Todo.parse_todo_section(readme)
      assert item.text == "Only item"
    end

    test "preserves correct line numbers" do
      readme = """
      # Project

      Some description here.
      More description.

      ## TODO
      - [ ] First item
      - [x] Second item
      """

      assert {:ok, items} = Todo.parse_todo_section(readme)
      assert [%{line_number: 7}, %{line_number: 8}] = items
    end
  end

  describe "first_unchecked/1" do
    test "returns first unchecked item from mixed list" do
      items = [
        %{checked: true, text: "Done", line_number: 1},
        %{checked: false, text: "Pending one", line_number: 2},
        %{checked: false, text: "Pending two", line_number: 3}
      ]

      assert {:ok, %{text: "Pending one", line_number: 2}} = Todo.first_unchecked(items)
    end

    test "returns error when all items are checked" do
      items = [
        %{checked: true, text: "Done one", line_number: 1},
        %{checked: true, text: "Done two", line_number: 2}
      ]

      assert {:error, :all_done} = Todo.first_unchecked(items)
    end

    test "returns error for empty list" do
      assert {:error, :all_done} = Todo.first_unchecked([])
    end
  end

  describe "check_todo_in_readme/2" do
    test "checks the matching unchecked item" do
      readme = """
      ## TODO
      - [ ] First item
      - [ ] Second item
      """

      assert {:ok, result} = Todo.check_todo_in_readme(readme, "First item")
      assert result =~ "- [x] First item"
      assert result =~ "- [ ] Second item"
    end

    test "matches lines with trailing whitespace" do
      readme = """
      ## TODO
      - [ ] Item with trailing space \

      - [ ] Clean item
      """

      assert {:ok, result} = Todo.check_todo_in_readme(readme, "Item with trailing space")
      assert result =~ "- [x] Item with trailing space"
      assert result =~ "- [ ] Clean item"
    end

    test "returns error when no matching item found" do
      readme = """
      ## TODO
      - [ ] Some other item
      """

      assert {:error, :not_found} = Todo.check_todo_in_readme(readme, "Nonexistent item")
    end

    test "skips already-checked items with same text" do
      readme = """
      ## TODO
      - [x] First item
      - [ ] First item
      """

      assert {:ok, result} = Todo.check_todo_in_readme(readme, "First item")
      lines = String.split(result, "\n")
      assert Enum.at(lines, 1) == "- [x] First item"
      assert Enum.at(lines, 2) == "- [x] First item"
    end

    test "returns ok unchanged when item is already checked" do
      readme = """
      ## TODO
      - [x] First item
      - [ ] Second item
      """

      assert {:ok, result} = Todo.check_todo_in_readme(readme, "First item")
      assert result == readme
    end

    test "does not check items outside ## TODO section" do
      readme = "- [ ] Outside item\n\n## TODO\n- [ ] Inside item\n\n## Other\n- [ ] Also outside"

      assert {:ok, result} = Todo.check_todo_in_readme(readme, "Inside item")
      assert result =~ "- [x] Inside item"
      assert result =~ "- [ ] Outside item"
      assert result =~ "- [ ] Also outside"
    end
  end

  describe "prune_checked_todos/1" do
    test "removes topmost checked when more than 3 checked exist" do
      readme = """
      ## TODO
      - [x] One
      - [x] Two
      - [x] Three
      - [x] Four
      - [ ] Pending
      """

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      refute result =~ "- [x] One"
      assert result =~ "- [x] Two"
      assert result =~ "- [x] Four"
      assert result =~ "- [ ] Pending"
    end

    test "no-op when 3 or fewer checked items" do
      readme = """
      ## TODO
      - [x] One
      - [x] Two
      - [x] Three
      - [ ] Pending
      """

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      assert result =~ "- [x] One"
      assert result =~ "- [x] Three"
    end

    test "leaves unchecked items alone" do
      readme = """
      ## TODO
      - [x] Done one
      - [x] Done two
      - [x] Done three
      - [x] Done four
      - [ ] Pending one
      - [ ] Pending two
      """

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      assert result =~ "- [ ] Pending one"
      assert result =~ "- [ ] Pending two"
    end

    test "does not prune checked items outside ## TODO section" do
      readme =
        "- [x] Outside one\n- [x] Outside two\n\n## TODO\n- [x] Alpha\n- [x] Bravo\n- [x] Charlie\n- [x] Delta\n- [ ] Pending\n\n## Other\n- [x] Also outside"

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      # All outside checked items must survive
      assert result =~ "- [x] Outside one"
      assert result =~ "- [x] Outside two"
      assert result =~ "- [x] Also outside"
      # Inside: 4 checked, prune to 3 → remove oldest (Alpha)
      refute result =~ "- [x] Alpha"
      assert result =~ "- [x] Bravo"
      assert result =~ "- [x] Delta"
      assert result =~ "- [ ] Pending"
    end

    test "removes indented bullet children along with checked parent" do
      readme = """
      ## TODO
      - [x] One
        - nested child of one
      - [x] Two
      - [x] Three
      - [x] Four
      - [ ] Pending
      """

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      refute result =~ "- [x] One"
      refute result =~ "nested child of one"
      assert result =~ "- [x] Two"
      assert result =~ "- [x] Three"
      assert result =~ "- [x] Four"
      assert result =~ "- [ ] Pending"
    end

    test "removes indented fenced code block along with checked parent" do
      readme = """
      ## TODO
      - [x] One
        ```sh
        mix compile
        ```
      - [x] Two
      - [x] Three
      - [x] Four
      - [ ] Pending
      """

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      refute result =~ "- [x] One"
      refute result =~ "mix compile"
      refute result =~ "```"
      assert result =~ "- [x] Two"
      assert result =~ "- [ ] Pending"
    end

    test "child range stops at next top-level checklist item" do
      readme = """
      ## TODO
      - [x] Alpha
        - child of alpha
      - [ ] Bravo
      - [x] Charlie
      - [x] Delta
      - [x] Echo
      """

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      refute result =~ "- [x] Alpha"
      refute result =~ "child of alpha"
      assert result =~ "- [ ] Bravo"
      assert result =~ "- [x] Charlie"
      assert result =~ "- [x] Delta"
      assert result =~ "- [x] Echo"
    end

    test "child range stops at blank line" do
      readme = """
      ## TODO
      - [x] One
        indented child

        indented after blank
      - [x] Two
      - [x] Three
      - [x] Four
      - [ ] Pending
      """

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      refute result =~ "- [x] One"
      refute result =~ "indented child"
      assert result =~ "indented after blank"
      assert result =~ "- [x] Two"
    end

    test "child range stops at next heading" do
      readme = """
      ## TODO
      - [x] One
        indented child of one
      ### Subsection
        indented under subsection
      - [x] Two
      - [x] Three
      - [x] Four
      - [ ] Pending
      """

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      refute result =~ "- [x] One"
      refute result =~ "indented child of one"
      assert result =~ "### Subsection"
      assert result =~ "indented under subsection"
      assert result =~ "- [x] Two"
    end

    test "does not remove indented lines outside the TODO section" do
      readme =
        "## Other\n- [x] Outside\n  indented under outside\n\n## TODO\n- [x] Alpha\n- [x] Bravo\n- [x] Charlie\n- [x] Delta\n- [ ] Pending\n"

      assert {:ok, result} = Todo.prune_checked_todos(readme)
      refute result =~ "- [x] Alpha"
      assert result =~ "- [x] Outside"
      assert result =~ "indented under outside"
      assert result =~ "- [x] Bravo"
      assert result =~ "- [ ] Pending"
    end
  end

  describe "new_changelog/1" do
    test "generates a fresh changelog with the entry" do
      result = Todo.new_changelog("Add user auth")
      assert result =~ "# Changelog"
      assert result =~ "Keep a Changelog"
      assert result =~ "## [Unreleased]"
      assert result =~ "### Added"
      assert result =~ "- Add user auth"
    end
  end

  describe "add_changelog_entry/2" do
    test "appends to existing unreleased Added section" do
      changelog = """
      # Changelog

      ## [Unreleased]

      ### Added

      - Existing entry
      """

      result = Todo.add_changelog_entry(changelog, "New feature")
      assert result =~ "- Existing entry\n- New feature"
    end

    test "creates Added subsection when unreleased exists without it" do
      changelog = """
      # Changelog

      ## [Unreleased]

      ### Fixed

      - Some fix
      """

      result = Todo.add_changelog_entry(changelog, "New feature")
      assert result =~ "### Added\n\n- New feature"
      assert result =~ "### Fixed"
    end

    test "does not cross subsection boundary when inserting under Added" do
      changelog =
        "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- Existing\n\n### Fixed\n\n- Some fix\n"

      result = Todo.add_changelog_entry(changelog, "New feature")
      lines = String.split(result, "\n")
      added_idx = Enum.find_index(lines, &(&1 == "### Added"))
      fixed_idx = Enum.find_index(lines, &(&1 == "### Fixed"))
      new_idx = Enum.find_index(lines, &(&1 == "- New feature"))

      assert new_idx > added_idx
      assert new_idx < fixed_idx
    end

    test "creates unreleased section when missing" do
      changelog = """
      # Changelog

      ## [1.0.0]

      ### Added

      - Initial release
      """

      result = Todo.add_changelog_entry(changelog, "New feature")
      assert result =~ "## [Unreleased]"
      assert result =~ "### Added\n\n- New feature"
      assert result =~ "## [1.0.0]"
    end

    test "inserts under [Unreleased] when versioned section also has ### Added" do
      changelog =
        "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- Existing unreleased\n\n## [1.0.0]\n\n### Added\n\n- Initial release\n"

      result = Todo.add_changelog_entry(changelog, "New feature")
      lines = String.split(result, "\n")

      unreleased_idx = Enum.find_index(lines, &(&1 == "## [Unreleased]"))
      version_idx = Enum.find_index(lines, &(&1 == "## [1.0.0]"))
      new_entry_idx = Enum.find_index(lines, &(&1 == "- New feature"))

      assert new_entry_idx > unreleased_idx,
             "entry should be after [Unreleased]"

      assert new_entry_idx < version_idx,
             "entry should be before [1.0.0]"

      # Versioned section should be untouched
      versioned_added_idx =
        lines
        |> Enum.with_index()
        |> Enum.find_value(fn {line, idx} ->
          if line == "### Added" and idx > version_idx, do: idx
        end)

      initial_idx = Enum.find_index(lines, &(&1 == "- Initial release"))
      assert initial_idx > versioned_added_idx
    end

    test "creates ### Added under [Unreleased] when only versioned section has it" do
      changelog =
        "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A fix\n\n## [1.0.0]\n\n### Added\n\n- Initial release\n"

      result = Todo.add_changelog_entry(changelog, "New feature")
      lines = String.split(result, "\n")

      unreleased_idx = Enum.find_index(lines, &(&1 == "## [Unreleased]"))
      version_idx = Enum.find_index(lines, &(&1 == "## [1.0.0]"))
      new_entry_idx = Enum.find_index(lines, &(&1 == "- New feature"))

      assert new_entry_idx > unreleased_idx
      assert new_entry_idx < version_idx

      # Should have created a new ### Added under [Unreleased]
      unreleased_added_idx =
        lines
        |> Enum.with_index()
        |> Enum.find_value(fn {line, idx} ->
          if line == "### Added" and idx > unreleased_idx and idx < version_idx, do: idx
        end)

      assert unreleased_added_idx != nil,
             "should create ### Added under [Unreleased]"

      assert new_entry_idx > unreleased_added_idx
    end
  end

  describe "build_prompt/2" do
    test "contains the TODO text" do
      result = Todo.build_prompt("Add user auth", "# Project\n\nSome readme.")
      assert result =~ "Add user auth"
    end

    test "contains the README contents" do
      result = Todo.build_prompt("Fix bug", "# Project\n\nBuild commands here.")
      assert result =~ "Build commands here."
    end

    test "contains TDD instructions" do
      result = Todo.build_prompt("Fix bug", "# Readme")
      assert result =~ "TDD"
    end

    test "contains mix todo --done callout" do
      result = Todo.build_prompt("Fix bug", "# Readme")
      assert result =~ "mix todo --done"
    end

    test "contains branch creation instructions" do
      result = Todo.build_prompt("Fix bug", "# Readme")
      assert result =~ "Create a feature branch from `main`"
      assert result =~ "todo/"
    end

    test "references AGENTS.md for conventions" do
      result = Todo.build_prompt("Fix bug", "# Readme")
      assert result =~ "AGENTS.md"
    end

    test "does not reference individual quality steps" do
      result = Todo.build_prompt("Fix bug", "# Readme")
      refute result =~ "Run `mix format`"
      refute result =~ "Run `mix credo"
      refute result =~ "Run `mix test`"
    end

    test "instructs to commit before running mix todo --done" do
      result = Todo.build_prompt("Fix bug", "# Readme")
      # "commit" should appear before "mix todo --done"
      commit_pos = result |> :binary.match("commit") |> elem(0)
      done_pos = result |> :binary.match("mix todo --done") |> elem(0)
      assert commit_pos < done_pos
    end

    test "instructs to push and create PR before waiting for review" do
      result = Todo.build_prompt("Fix bug", "# Readme")
      assert result =~ "gh pr create"
      pr_pos = result |> :binary.match("gh pr create") |> elem(0)
      wait_pos = result |> :binary.match("Stop and wait") |> elem(0)
      assert pr_pos < wait_pos
    end

    test "instructs to stop and wait for review before finalizing" do
      result = Todo.build_prompt("Fix bug", "# Readme")
      assert result =~ "Stop and wait for review"
    end
  end

  describe "extract_pr_url/1" do
    test "returns URL when output is just a URL" do
      assert {:ok, "https://github.com/org/repo/pull/1"} =
               Todo.extract_pr_url("https://github.com/org/repo/pull/1")
    end

    test "extracts URL from output with warnings" do
      output = "Warning: 6 uncommitted changes\nhttps://github.com/org/repo/pull/1"

      assert {:ok, "https://github.com/org/repo/pull/1"} =
               Todo.extract_pr_url(output)
    end

    test "returns error when no URL found" do
      assert {:error, :no_pr_url} = Todo.extract_pr_url("some random output")
    end
  end

  describe "build_done_prompt/2" do
    test "contains the PR URL" do
      result = Todo.build_done_prompt("Add auth", "https://github.com/org/repo/pull/42")
      assert result =~ "https://github.com/org/repo/pull/42"
    end

    test "indicates PR was merged" do
      result = Todo.build_done_prompt("Add auth", "https://github.com/org/repo/pull/42")
      assert result =~ "merged"
    end
  end
end
