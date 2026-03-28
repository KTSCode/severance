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

  describe "slugify/1" do
    test "converts spaces to hyphens and downcases" do
      assert "add-user-authentication" = Todo.slugify("Add User Authentication")
    end

    test "strips special characters" do
      assert "fix-bug-in-config" = Todo.slugify("Fix bug (in config!)")
    end

    test "truncates to 60 characters" do
      long = String.duplicate("word ", 20)
      slug = Todo.slugify(long)
      assert String.length(slug) <= 60
    end

    test "trims leading and trailing hyphens" do
      assert "clean-slug" = Todo.slugify("--clean slug--")
    end

    test "collapses consecutive hyphens" do
      assert "a-b-c" = Todo.slugify("a   b   c")
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
  end

  describe "build_prompt/2" do
    test "contains the TODO text" do
      result = Todo.build_prompt("Add user auth", "# Project\n\nSome readme.")
      assert result =~ "Add user auth"
    end

    test "contains the README contents" do
      readme = "# Project\n\nBuild commands here."
      result = Todo.build_prompt("Fix bug", readme)
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
  end

  describe "build_done_prompt/2" do
    test "contains the PR URL" do
      result = Todo.build_done_prompt("Add auth", "https://github.com/org/repo/pull/42")
      assert result =~ "https://github.com/org/repo/pull/42"
    end

    test "contains CHANGELOG review instructions" do
      result = Todo.build_done_prompt("Add auth", "https://github.com/org/repo/pull/42")
      assert result =~ "CHANGELOG"
      assert result =~ "Added"
    end
  end
end
