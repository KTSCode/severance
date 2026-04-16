defmodule Mix.Tasks.Changelog.FinalizeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Changelog.Finalize

  describe "parse_bump_flag/1" do
    test "parses --major" do
      assert {:ok, :major} = Finalize.parse_bump_flag(["--major"])
    end

    test "parses --minor" do
      assert {:ok, :minor} = Finalize.parse_bump_flag(["--minor"])
    end

    test "parses --patch" do
      assert {:ok, :patch} = Finalize.parse_bump_flag(["--patch"])
    end

    test "returns error for unknown flag" do
      assert {:error, :invalid_flag} = Finalize.parse_bump_flag(["--invalid"])
    end

    test "returns error for empty args" do
      assert {:error, :invalid_flag} = Finalize.parse_bump_flag([])
    end
  end

  describe "bump_version/2" do
    test "bumps major version" do
      assert {:ok, "1.0.0"} = Finalize.bump_version("0.1.0", :major)
    end

    test "bumps minor version" do
      assert {:ok, "0.2.0"} = Finalize.bump_version("0.1.0", :minor)
    end

    test "bumps patch version" do
      assert {:ok, "0.1.1"} = Finalize.bump_version("0.1.0", :patch)
    end

    test "major resets minor and patch" do
      assert {:ok, "2.0.0"} = Finalize.bump_version("1.3.5", :major)
    end

    test "minor resets patch" do
      assert {:ok, "1.4.0"} = Finalize.bump_version("1.3.5", :minor)
    end

    test "returns error for invalid version" do
      assert {:error, :invalid_version} = Finalize.bump_version("not.a.version", :minor)
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

      assert {:ok, entries} = Finalize.unreleased_entries(changelog)
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

      assert {:error, :empty_unreleased} = Finalize.unreleased_entries(changelog)
    end

    test "returns error when unreleased section has only headings" do
      changelog =
        "# Changelog\n\n## [Unreleased]\n\n### Added\n\n### Fixed\n\n## [0.1.0] -- 2026-03-29\n"

      assert {:error, :empty_unreleased} = Finalize.unreleased_entries(changelog)
    end

    test "returns error when no unreleased section exists" do
      changelog = """
      # Changelog

      ## [0.1.0] -- 2026-03-29

      ### Added

      - Initial release
      """

      assert {:error, :no_unreleased} = Finalize.unreleased_entries(changelog)
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

      result = Finalize.finalize_changelog(changelog, "0.2.0", "2026-04-01")
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

      result = Finalize.finalize_changelog(changelog, "0.2.0", "2026-04-01")
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

      result = Finalize.finalize_changelog(changelog, "0.2.0", "2026-04-01")
      assert result =~ "## [0.2.0] -- 2026-04-01"
      assert result =~ "### Added\n\n- New thing"
      assert result =~ "### Fixed\n\n- Bug fix"
    end
  end
end
