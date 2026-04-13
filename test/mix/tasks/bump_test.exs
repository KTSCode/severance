defmodule Mix.Tasks.BumpTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bump

  describe "parse_hex_outdated/1" do
    test "parses 4-column format (no Only column)" do
      output = """
      Dependency          Current  Latest  Status
      credo               1.7.5    1.7.7   Update possible
      dialyxir            1.4.3    1.4.5   Update possible
      """

      result = Bump.parse_hex_outdated(output)

      assert [
               %{name: "credo", current: "1.7.5", latest: "1.7.7", status: "Update possible"},
               %{name: "dialyxir", current: "1.4.3", latest: "1.4.5", status: "Update possible"}
             ] = result
    end

    test "parses 5-column format with Only environment column" do
      output = """
      Dependency   Only      Current  Latest  Status
      bandit       dev       1.10.4   1.10.4  Up-to-date
      credo        dev,test  1.7.17   1.7.18  Update possible
      burrito                1.5.0    1.5.0   Up-to-date
      """

      result = Bump.parse_hex_outdated(output)

      assert [
               %{name: "bandit", current: "1.10.4", latest: "1.10.4", status: "Up-to-date"},
               %{name: "credo", current: "1.7.17", latest: "1.7.18", status: "Update possible"},
               %{name: "burrito", current: "1.5.0", latest: "1.5.0", status: "Up-to-date"}
             ] = result
    end

    test "strips ANSI escape codes" do
      output = "\e[33mcredo\e[0m               1.7.5    \e[31m1.7.7\e[0m   Update possible\n"

      result = Bump.parse_hex_outdated("Dependency Current Latest Status\n" <> output)

      assert [%{name: "credo", current: "1.7.5", latest: "1.7.7"}] = result
    end

    test "returns empty list for no dependencies" do
      output = "Dependency  Current  Latest  Status\n"
      assert [] = Bump.parse_hex_outdated(output)
    end

    test "returns empty list for all-up-to-date message" do
      output = "All dependencies are up to date"
      assert [] = Bump.parse_hex_outdated(output)
    end
  end

  describe "parse_tool_versions/1" do
    test "parses standard .tool-versions content" do
      content = """
      erlang 28.2
      elixir 1.19.5-otp-28
      zig 0.15.2
      """

      assert %{
               "erlang" => "28.2",
               "elixir" => "1.19.5-otp-28",
               "zig" => "0.15.2"
             } = Bump.parse_tool_versions(content)
    end

    test "skips blank lines and comments" do
      content = """
      # Runtime versions
      erlang 28.2

      elixir 1.19.5-otp-28
      """

      result = Bump.parse_tool_versions(content)
      assert map_size(result) == 2
      assert result["erlang"] == "28.2"
      assert result["elixir"] == "1.19.5-otp-28"
    end

    test "returns empty map for empty content" do
      assert %{} = Bump.parse_tool_versions("")
    end
  end

  describe "parse_latest_runtime/1" do
    test "parses a clean version string" do
      assert {:ok, "28.3"} = Bump.parse_latest_runtime("28.3\n")
    end

    test "trims whitespace" do
      assert {:ok, "1.19.6"} = Bump.parse_latest_runtime("  1.19.6  \n")
    end

    test "returns error for empty output" do
      assert {:error, :unavailable} = Bump.parse_latest_runtime("")
    end

    test "returns error for error messages" do
      assert {:error, :unavailable} = Bump.parse_latest_runtime("No compatible versions available")
    end
  end

  describe "runtime_updates/2" do
    test "returns updates where versions differ" do
      current = %{"erlang" => "28.2", "elixir" => "1.19.5-otp-28", "zig" => "0.15.2"}
      latest = %{"erlang" => "28.3", "elixir" => "1.19.5-otp-28", "zig" => "0.15.3"}

      result = Bump.runtime_updates(current, latest)

      assert length(result) == 2
      assert %{tool: "erlang", current: "28.2", latest: "28.3"} in result
      assert %{tool: "zig", current: "0.15.2", latest: "0.15.3"} in result
    end

    test "returns empty list when all versions match" do
      versions = %{"erlang" => "28.2", "elixir" => "1.19.5-otp-28"}
      assert [] = Bump.runtime_updates(versions, versions)
    end

    test "skips tools missing from latest" do
      current = %{"erlang" => "28.2", "zig" => "0.15.2"}
      latest = %{"erlang" => "28.3"}

      result = Bump.runtime_updates(current, latest)
      assert [%{tool: "erlang"}] = result
    end
  end

  describe "format_outdated_table/1" do
    test "formats deps as a markdown table" do
      deps = [
        %{name: "credo", current: "1.7.5", latest: "1.7.7", status: "Update possible"},
        %{name: "dialyxir", current: "1.4.3", latest: "1.4.5", status: "Update possible"}
      ]

      result = Bump.format_outdated_table(deps)
      assert result =~ "| Package"
      assert result =~ "| credo"
      assert result =~ "| dialyxir"
      assert result =~ "1.7.5"
      assert result =~ "1.7.7"
    end

    test "returns message when list is empty" do
      assert Bump.format_outdated_table([]) =~ "up to date"
    end
  end

  describe "format_runtime_table/1" do
    test "formats runtime updates as a markdown table" do
      updates = [
        %{tool: "erlang", current: "28.2", latest: "28.3"},
        %{tool: "zig", current: "0.15.2", latest: "0.15.3"}
      ]

      result = Bump.format_runtime_table(updates)
      assert result =~ "| Tool"
      assert result =~ "| erlang"
      assert result =~ "| zig"
    end

    test "returns message when list is empty" do
      assert Bump.format_runtime_table([]) =~ "at latest"
    end
  end

  describe "build_prompt/1" do
    test "includes all sections in order" do
      data = %{
        outdated_table:
          "| Package | Current | Latest | Status |\n|---|---|---|---|\n| credo | 1.7.5 | 1.7.7 | Update possible |",
        runtime_table: "All runtimes are at latest versions.",
        mix_exs: ~s(defmodule Severance.MixProject do\nend),
        mix_lock: ~s(%{"credo": {:hex, :credo}}),
        config_files: [{"config/config.exs", "import Config"}]
      }

      result = Bump.build_prompt(data)

      assert result =~ "# Outdated Dependencies"
      assert result =~ "| credo |"
      assert result =~ "# Runtime Versions"
      assert result =~ "at latest"
      assert result =~ "# mix.exs"
      assert result =~ "defmodule Severance.MixProject"
      assert result =~ "# mix.lock"
      assert result =~ "credo"
      assert result =~ "# config/config.exs"
      assert result =~ "import Config"
      assert result =~ "# Instructions"
      assert result =~ "mix quality"
    end

    test "handles multiple config files" do
      data = %{
        outdated_table: "All dependencies are up to date.",
        runtime_table: "All runtimes are at latest versions.",
        mix_exs: "mix_exs_content",
        mix_lock: "mix_lock_content",
        config_files: [
          {"config/config.exs", "config_content"},
          {"config/dev.exs", "dev_content"},
          {"config/runtime.exs", "runtime_content"}
        ]
      }

      result = Bump.build_prompt(data)
      assert result =~ "# config/config.exs"
      assert result =~ "# config/dev.exs"
      assert result =~ "# config/runtime.exs"
    end

    test "handles empty config files list" do
      data = %{
        outdated_table: "All dependencies are up to date.",
        runtime_table: "All runtimes are at latest versions.",
        mix_exs: "mix_exs_content",
        mix_lock: "mix_lock_content",
        config_files: []
      }

      result = Bump.build_prompt(data)
      assert result =~ "# Instructions"
    end
  end
end
