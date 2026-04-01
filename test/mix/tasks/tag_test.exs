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
end
