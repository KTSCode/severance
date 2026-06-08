defmodule Mix.Tasks.LoopTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Loop

  defp issue(overrides \\ %{}) do
    Map.merge(
      %{number: 42, title: "Add dark mode", body: "It would be nice to have dark mode.", labels: []},
      overrides
    )
  end

  describe "parse_issues/1" do
    test "decodes a single issue with label names" do
      json = ~s([{"number":42,"title":"Add dark mode","body":"Please","labels":[{"name":"feature"}]}])

      assert {:ok, [item]} = Loop.parse_issues(json)
      assert item.number == 42
      assert item.title == "Add dark mode"
      assert item.body == "Please"
      assert item.labels == ["feature"]
    end

    test "decodes multiple issues preserving order" do
      json =
        ~s([{"number":1,"title":"One","body":"a","labels":[]},) <>
          ~s({"number":2,"title":"Two","body":"b","labels":[]}])

      assert {:ok, [first, second]} = Loop.parse_issues(json)
      assert first.number == 1
      assert second.number == 2
    end

    test "coerces a null body to an empty string" do
      json = ~s([{"number":7,"title":"Null body","body":null,"labels":[]}])

      assert {:ok, [item]} = Loop.parse_issues(json)
      assert item.body == ""
    end

    test "defaults missing labels to an empty list" do
      json = ~s([{"number":7,"title":"No labels","body":"x"}])

      assert {:ok, [item]} = Loop.parse_issues(json)
      assert item.labels == []
    end

    test "returns error for malformed json" do
      assert {:error, :invalid_json} = Loop.parse_issues("not json")
    end

    test "returns error when the top level is not an array" do
      assert {:error, :invalid_json} = Loop.parse_issues(~s({"number":1}))
    end
  end

  describe "parse_issue/1" do
    test "decodes a single object" do
      json = ~s({"number":99,"title":"Crash","body":"boom","labels":[{"name":"bug"}]})

      assert {:ok, item} = Loop.parse_issue(json)
      assert item.number == 99
      assert item.labels == ["bug"]
    end

    test "returns error when the top level is an array" do
      assert {:error, :invalid_json} = Loop.parse_issue(~s([{"number":1}]))
    end

    test "returns error for malformed json" do
      assert {:error, :invalid_json} = Loop.parse_issue("{")
    end
  end

  describe "first_open_issue/1" do
    test "returns the first issue" do
      assert {:ok, %{number: 1}} = Loop.first_open_issue([issue(%{number: 1}), issue(%{number: 2})])
    end

    test "returns error for an empty list" do
      assert {:error, :no_issues} = Loop.first_open_issue([])
    end
  end

  describe "classify_issue/1" do
    test "classifies a bug label as :bug" do
      assert Loop.classify_issue(issue(%{labels: ["bug"]})) == :bug
    end

    test "treats fix, defect, regression, and debug as bugs" do
      for label <- ["fix", "defect", "regression", "debug"] do
        assert Loop.classify_issue(issue(%{labels: [label]})) == :bug
      end
    end

    test "is case-insensitive" do
      assert Loop.classify_issue(issue(%{labels: ["Bug"]})) == :bug
    end

    test "classifies anything else as :feature" do
      assert Loop.classify_issue(issue(%{labels: ["enhancement"]})) == :feature
    end

    test "classifies an unlabeled issue as :feature" do
      assert Loop.classify_issue(issue(%{labels: []})) == :feature
    end
  end

  describe "slugify/1" do
    test "replaces spaces with hyphens and downcases" do
      assert Loop.slugify("Add Dark Mode") == "add-dark-mode"
    end

    test "strips special characters" do
      assert Loop.slugify("Fix crash on start!") == "fix-crash-on-start"
    end

    test "trims leading and trailing hyphens" do
      assert Loop.slugify("  spaced  ") == "spaced"
    end

    test "truncates long titles" do
      slug = Loop.slugify(String.duplicate("a", 100))
      assert String.length(slug) <= 50
    end
  end

  describe "build_branch_name/2" do
    test "uses the feature prefix for features" do
      assert Loop.build_branch_name(issue(), :feature) == "feature/42-add-dark-mode"
    end

    test "uses the fix prefix for bugs" do
      assert Loop.build_branch_name(issue(%{number: 7, title: "Crash"}), :bug) == "fix/7-crash"
    end

    test "falls back to just the number when the title has no slug" do
      assert Loop.build_branch_name(issue(%{number: 5, title: "!!!"}), :feature) == "feature/5"
    end
  end

  describe "pr_title/2" do
    test "prefixes features with feat:" do
      assert Loop.pr_title(issue(), :feature) == "feat: Add dark mode (#42)"
    end

    test "prefixes bugs with fix:" do
      assert Loop.pr_title(issue(%{number: 7, title: "Crash"}), :bug) == "fix: Crash (#7)"
    end
  end

  describe "commit_message/2" do
    test "includes the subject and a Closes trailer" do
      message = Loop.commit_message(issue(), :feature)
      assert message =~ "feat: Add dark mode (#42)"
      assert message =~ "Closes #42"
    end
  end

  describe "build_initial_prompt/3" do
    test "includes the issue number, title, and body" do
      prompt = Loop.build_initial_prompt(issue(), :feature, "# Readme")
      assert prompt =~ "#42"
      assert prompt =~ "Add dark mode"
      assert prompt =~ "It would be nice to have dark mode."
    end

    test "includes the README context" do
      prompt = Loop.build_initial_prompt(issue(), :feature, "Build commands here.")
      assert prompt =~ "Build commands here."
    end

    test "instructs TDD and references AGENTS.md" do
      prompt = Loop.build_initial_prompt(issue(), :feature, "# Readme")
      assert prompt =~ "TDD"
      assert prompt =~ "AGENTS.md"
    end

    test "names mix quality as the verification gate" do
      prompt = Loop.build_initial_prompt(issue(), :feature, "# Readme")
      assert prompt =~ "mix quality"
    end

    test "tells the agent not to commit or open a PR" do
      prompt = Loop.build_initial_prompt(issue(), :feature, "# Readme")
      assert prompt =~ "Do not commit"
    end

    test "frames a bug as reproduce-then-fix" do
      prompt = Loop.build_initial_prompt(issue(%{labels: ["bug"]}), :bug, "# Readme")
      assert prompt =~ "reproduce"
    end

    test "frames a feature as implement" do
      prompt = Loop.build_initial_prompt(issue(), :feature, "# Readme")
      assert prompt =~ "implement"
    end
  end

  describe "build_retry_prompt/5" do
    test "includes the iteration number and budget" do
      prompt = Loop.build_retry_prompt(issue(), :feature, "boom", 2, 5)
      assert prompt =~ "2"
      assert prompt =~ "5"
    end

    test "includes the failure output" do
      prompt = Loop.build_retry_prompt(issue(), :feature, "** (RuntimeError) boom", 2, 5)
      assert prompt =~ "** (RuntimeError) boom"
    end

    test "tells the agent to fix without reverting progress" do
      prompt = Loop.build_retry_prompt(issue(), :feature, "boom", 2, 5)
      assert prompt =~ "without reverting"
    end

    test "names mix quality as the gate" do
      prompt = Loop.build_retry_prompt(issue(), :feature, "boom", 2, 5)
      assert prompt =~ "mix quality"
    end
  end

  describe "summarize_failure/2" do
    test "keeps the last n lines" do
      output = Enum.map_join(1..100, "\n", &"line #{&1}")
      summary = Loop.summarize_failure(output, 10)

      assert summary =~ "line 100"
      assert summary =~ "line 91"
      refute summary =~ "line 90"
    end

    test "returns short output unchanged" do
      assert Loop.summarize_failure("only line", 10) == "only line"
    end
  end

  describe "quality_passed?/1" do
    test "true for exit code 0" do
      assert Loop.quality_passed?(0)
    end

    test "false for a non-zero exit code" do
      refute Loop.quality_passed?(1)
    end
  end

  describe "should_continue?/3" do
    test "done when quality passed" do
      assert Loop.should_continue?(true, 1, 5) == :done
    end

    test "retry when failing with budget remaining" do
      assert Loop.should_continue?(false, 2, 5) == :retry
    end

    test "exhausted when failing on the last iteration" do
      assert Loop.should_continue?(false, 5, 5) == :exhausted
    end
  end

  describe "claude_args/1" do
    test "runs headless with the prompt and skips permission prompts" do
      args = Loop.claude_args("do the thing")
      assert Enum.at(args, 0) == "-p"
      assert Enum.at(args, 1) == "do the thing"
      assert "--dangerously-skip-permissions" in args
    end
  end

  describe "build_summary/4" do
    test "done summary names the issue and iteration count" do
      summary = Loop.build_summary(issue(), :feature, :done, 3)
      assert summary =~ "#42"
      assert summary =~ "Add dark mode"
      assert summary =~ "3"
      assert summary =~ "mix quality"
    end

    test "exhausted summary signals the loop did not complete" do
      summary = Loop.build_summary(issue(), :bug, :exhausted, 5)
      assert summary =~ "#42"
      assert summary =~ "still failing"
    end
  end

  describe "extract_pr_url/1" do
    test "returns the URL when output is just a URL" do
      assert {:ok, "https://github.com/org/repo/pull/1"} =
               Loop.extract_pr_url("https://github.com/org/repo/pull/1")
    end

    test "extracts the URL from output with warnings" do
      output = "Warning: 3 uncommitted changes\nhttps://github.com/org/repo/pull/1"
      assert {:ok, "https://github.com/org/repo/pull/1"} = Loop.extract_pr_url(output)
    end

    test "returns error when no URL is present" do
      assert {:error, :no_pr_url} = Loop.extract_pr_url("nothing here")
    end
  end
end
