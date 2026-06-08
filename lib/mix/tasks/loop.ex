defmodule Mix.Tasks.Loop do
  @shortdoc "Autonomously build or debug a GitHub issue with an AI loop"

  @moduledoc """
  Drives a self-correcting AI loop against a GitHub issue.

  `mix loop` picks an open issue, classifies it as a feature or a bug,
  and repeatedly invokes `claude` headless to implement (or fix) it,
  verifying each attempt with `mix quality`. Failing output is fed back
  into the next attempt until the suite passes or the iteration budget is
  spent. On success it commits, pushes, opens a PR that closes the issue,
  and comments the outcome back on the issue.

  ## Usage

      mix loop                 # work the next open issue
      mix loop --issue 42      # work a specific issue
      mix loop --label bug     # only consider issues with this label
      mix loop --max 8         # cap the loop at 8 attempts (default 5)
      mix loop --full          # run the full `mix quality` each iteration

  Unlike `mix todo`, the loop opens a PR for human review rather than
  merging it.
  """

  use Mix.Task

  @type issue :: %{
          number: integer(),
          title: String.t(),
          body: String.t(),
          labels: [String.t()]
        }

  @type mode :: :feature | :bug
  @type outcome :: :done | :exhausted

  @default_max 5
  @bug_labels ~w(bug fix defect regression debug)
  @claude_flags ["--dangerously-skip-permissions"]
  @issue_fields "number,title,body,labels"

  @doc """
  Decodes a `gh issue list --json` array into a list of issue maps.

  Returns `{:error, :invalid_json}` for malformed input or when the top
  level is not a JSON array.
  """
  @spec parse_issues(String.t()) :: {:ok, [issue()]} | {:error, :invalid_json}
  def parse_issues(json) do
    case decode(json) do
      {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &to_issue/1)}
      {:ok, _other} -> {:error, :invalid_json}
      :error -> {:error, :invalid_json}
    end
  end

  @doc """
  Decodes a `gh issue view --json` object into a single issue map.

  Returns `{:error, :invalid_json}` for malformed input or when the top
  level is not a JSON object.
  """
  @spec parse_issue(String.t()) :: {:ok, issue()} | {:error, :invalid_json}
  def parse_issue(json) do
    case decode(json) do
      {:ok, %{} = obj} -> {:ok, to_issue(obj)}
      {:ok, _other} -> {:error, :invalid_json}
      :error -> {:error, :invalid_json}
    end
  end

  @doc """
  Returns the first issue in the list, or `{:error, :no_issues}` when empty.
  """
  @spec first_open_issue([issue()]) :: {:ok, issue()} | {:error, :no_issues}
  def first_open_issue([]), do: {:error, :no_issues}
  def first_open_issue([issue | _]), do: {:ok, issue}

  @doc """
  Classifies an issue as `:bug` or `:feature` from its labels.

  Any label in `#{inspect(@bug_labels)}` (case-insensitive) marks the
  issue as a bug; everything else is treated as a feature.

  ## Examples

      iex> Mix.Tasks.Loop.classify_issue(%{number: 1, title: "x", body: "", labels: ["bug"]})
      :bug

      iex> Mix.Tasks.Loop.classify_issue(%{number: 1, title: "x", body: "", labels: []})
      :feature
  """
  @spec classify_issue(issue()) :: mode()
  def classify_issue(%{labels: labels}) do
    normalized = Enum.map(labels, &String.downcase/1)
    if Enum.any?(normalized, &(&1 in @bug_labels)), do: :bug, else: :feature
  end

  @doc """
  Turns free text into a branch-safe slug, truncated to 50 characters.

  ## Examples

      iex> Mix.Tasks.Loop.slugify("Add Dark Mode!")
      "add-dark-mode"
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 50)
  end

  @doc """
  Builds the working branch name for an issue, e.g. `feature/42-add-auth`.

  Bugs use the `fix/` prefix; features use `feature/`. When the title has
  no usable slug, only the issue number is used.
  """
  @spec build_branch_name(issue(), mode()) :: String.t()
  def build_branch_name(%{number: number, title: title}, mode) do
    prefix = branch_prefix(mode)

    case slugify(title) do
      "" -> "#{prefix}/#{number}"
      slug -> "#{prefix}/#{number}-#{slug}"
    end
  end

  @doc """
  Builds the PR / commit subject line, e.g. `feat: Add auth (#42)`.
  """
  @spec pr_title(issue(), mode()) :: String.t()
  def pr_title(%{number: number, title: title}, mode) do
    "#{title_prefix(mode)}: #{title} (##{number})"
  end

  @doc """
  Builds the commit message: the subject line plus a `Closes #N` trailer.
  """
  @spec commit_message(issue(), mode()) :: String.t()
  def commit_message(%{number: number} = issue, mode) do
    "#{pr_title(issue, mode)}\n\nCloses ##{number}"
  end

  @doc """
  Builds the first-attempt agent prompt: the issue, the README context, and
  TDD instructions framed for a feature or a bug.
  """
  @spec build_initial_prompt(issue(), mode(), String.t()) :: String.t()
  def build_initial_prompt(issue, mode, readme) do
    """
    You are working autonomously on the Severance project, driven by `mix loop`.

    #{task_line(issue, mode)}

    # Issue ##{issue.number}: #{issue.title}

    #{issue_body(issue)}

    ## Project Context

    #{readme}

    ## Instructions

    1. Read AGENTS.md and the codebase to understand the conventions and patterns.
    2. Follow TDD. #{tdd_note(mode)}
    3. Keep your changes focused on this issue. Do not edit CHANGELOG.md.
    4. Your work is verified by `mix quality` — it must pass with zero failures.
    5. Do not commit, push, or open a pull request. `mix loop` does that once
       `mix quality` is green.
    """
  end

  @doc """
  Builds a retry prompt that feeds the previous `mix quality` failure back
  to the agent, noting the iteration number and budget.
  """
  @spec build_retry_prompt(issue(), mode(), String.t(), pos_integer(), pos_integer()) ::
          String.t()
  def build_retry_prompt(issue, _mode, failure_output, iteration, max) do
    """
    You are on iteration #{iteration} of #{max}, still working on GitHub issue
    ##{issue.number} inside `mix loop`.

    The previous attempt did not pass `mix quality`. Here is the tail of the
    output:

    ```
    #{failure_output}
    ```

    Fix the failures above without reverting the progress you have already made.
    Keep following TDD and the conventions in AGENTS.md. `mix quality` must pass.
    """
  end

  @doc """
  Keeps the last `max_lines` lines of command output.

  Quality failures land at the end of the output, so the tail carries the
  most useful signal for the retry prompt while keeping it compact.
  """
  @spec summarize_failure(String.t(), pos_integer()) :: String.t()
  def summarize_failure(output, max_lines \\ 40) do
    lines = String.split(output, "\n")

    lines
    |> Enum.drop(max(length(lines) - max_lines, 0))
    |> Enum.join("\n")
  end

  @doc """
  Returns `true` when `mix quality` exited successfully.

  ## Examples

      iex> Mix.Tasks.Loop.quality_passed?(0)
      true

      iex> Mix.Tasks.Loop.quality_passed?(1)
      false
  """
  @spec quality_passed?(integer()) :: boolean()
  def quality_passed?(exit_code), do: exit_code == 0

  @doc """
  Decides what the loop does after an attempt.

  Returns `:done` once quality passes, `:retry` while attempts remain, and
  `:exhausted` when the budget is spent on a still-failing run.

  ## Examples

      iex> Mix.Tasks.Loop.should_continue?(true, 1, 5)
      :done

      iex> Mix.Tasks.Loop.should_continue?(false, 5, 5)
      :exhausted
  """
  @spec should_continue?(boolean(), pos_integer(), pos_integer()) :: :done | :retry | :exhausted
  def should_continue?(true, _iteration, _max), do: :done
  def should_continue?(false, iteration, max) when iteration >= max, do: :exhausted
  def should_continue?(false, _iteration, _max), do: :retry

  @doc """
  Builds the argv for a headless `claude` invocation.

  Uses print mode (`-p`) so the call returns when the agent is done, and
  skips interactive permission prompts so it can edit files unattended.
  """
  @spec claude_args(String.t()) :: [String.t()]
  def claude_args(prompt), do: ["-p", prompt | @claude_flags]

  @doc """
  Builds the human-readable summary printed to stdout and posted on the
  issue, for both the `:done` and `:exhausted` outcomes.
  """
  @spec build_summary(issue(), mode(), outcome(), non_neg_integer()) :: String.t()
  def build_summary(issue, mode, :done, iterations) do
    """
    Loop complete for issue ##{issue.number} (#{mode_label(mode)}): #{issue.title}
    Passed `mix quality` after #{iterations} iteration(s).
    """
  end

  def build_summary(issue, mode, :exhausted, iterations) do
    """
    Loop could not complete issue ##{issue.number} (#{mode_label(mode)}): #{issue.title}
    `mix quality` is still failing after #{iterations} iteration(s). The branch
    has been left in place for manual review.
    """
  end

  @doc """
  Extracts the PR URL from `gh pr create` output, which may prepend
  warnings before the URL on its final line.
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

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [issue: :integer, label: :string, max: :integer, full: :boolean]
      )

    loop(File.cwd!(), opts)
  end

  @doc false
  def loop(root \\ File.cwd!(), opts \\ []) do
    max = opts[:max] || @default_max
    full? = opts[:full] || false

    with :ok <- check_gh_installed(),
         :ok <- check_claude_installed(),
         {:ok, readme} <- read_readme(root),
         {:ok, issue} <- fetch_issue(opts),
         mode = classify_issue(issue),
         branch = build_branch_name(issue, mode),
         :ok <- checkout_branch(branch) do
      case run_loop(issue, mode, readme, max, full?) do
        {:ok, iterations} -> finalize(issue, mode, branch, iterations)
        {:exhausted, iterations, failure} -> report_exhausted(issue, mode, iterations, failure)
        {:error, _} = error -> handle_error(error)
      end
    else
      error -> handle_error(error)
    end
  end

  # --- Loop ---

  defp run_loop(issue, mode, readme, max, full?) do
    iterate(issue, mode, readme, max, full?, 1, nil)
  end

  defp iterate(issue, mode, readme, max, full?, iteration, previous_failure) do
    prompt = prompt_for(issue, mode, readme, max, iteration, previous_failure)
    stderr("Iteration #{iteration}/#{max}: invoking claude...")

    with {:ok, _output} <- run_claude(prompt) do
      stderr("Iteration #{iteration}/#{max}: running mix quality...")
      {quality_output, exit_code} = run_quality(full?)

      case should_continue?(quality_passed?(exit_code), iteration, max) do
        :done ->
          {:ok, iteration}

        :exhausted ->
          {:exhausted, iteration, summarize_failure(quality_output)}

        :retry ->
          failure = summarize_failure(quality_output)
          iterate(issue, mode, readme, max, full?, iteration + 1, failure)
      end
    end
  end

  defp prompt_for(issue, mode, readme, _max, 1, _previous) do
    build_initial_prompt(issue, mode, readme)
  end

  defp prompt_for(issue, mode, _readme, max, iteration, previous) do
    build_retry_prompt(issue, mode, previous, iteration, max)
  end

  # --- Finalize ---

  defp finalize(issue, mode, branch, iterations) do
    summary = build_summary(issue, mode, :done, iterations)

    with :ok <- git_commit(issue, mode),
         :ok <- git_push(branch),
         {:ok, pr_url} <- ensure_pr(issue, mode),
         :ok <- comment_issue(issue, "#{summary}\nPR: #{pr_url}") do
      IO.write("#{summary}PR: #{pr_url}\n")
    else
      error -> handle_error(error)
    end
  end

  defp report_exhausted(issue, mode, iterations, failure) do
    summary = build_summary(issue, mode, :exhausted, iterations)
    comment_issue(issue, "#{summary}\n```\n#{failure}\n```")
    stderr(summary)
    exit({:shutdown, 1})
  end

  # --- Side-effect helpers ---

  defp cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {output, code}}
    end
  end

  defp check_gh_installed do
    if System.find_executable("gh"), do: :ok, else: {:error, :no_gh}
  end

  defp check_claude_installed do
    if System.find_executable("claude"), do: :ok, else: {:error, :no_claude}
  end

  defp read_readme(root) do
    case File.read(Path.join(root, "README.md")) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :no_readme}
    end
  end

  defp fetch_issue(opts) do
    case opts[:issue] do
      nil -> fetch_next_issue(opts[:label])
      number -> fetch_issue_by_number(number)
    end
  end

  defp fetch_next_issue(label) do
    args = ["issue", "list", "--state", "open", "--json", @issue_fields, "--limit", "30"]

    with {:ok, output} <- cmd("gh", args ++ label_args(label)),
         {:ok, issues} <- parse_issues(output) do
      first_open_issue(issues)
    end
  end

  defp fetch_issue_by_number(number) do
    args = ["issue", "view", Integer.to_string(number), "--json", @issue_fields]

    with {:ok, output} <- cmd("gh", args) do
      parse_issue(output)
    end
  end

  defp label_args(nil), do: []
  defp label_args(label), do: ["--label", label]

  defp checkout_branch(branch) do
    stderr("Preparing branch #{branch}...")

    with {:ok, _} <- cmd("git", ["checkout", "-B", branch]) do
      :ok
    end
  end

  defp run_claude(prompt) do
    case System.cmd("claude", claude_args(prompt), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {output, code}}
    end
  end

  defp run_quality(full?) do
    System.cmd("mix", quality_args(full?), stderr_to_stdout: true)
  end

  defp quality_args(true), do: ["quality"]
  defp quality_args(false), do: ["quality", "--quick"]

  defp git_commit(issue, mode) do
    stderr("Committing changes...")

    with {:ok, _} <- cmd("git", ["add", "-A"]) do
      commit_or_detect_empty(commit_message(issue, mode))
    end
  end

  defp commit_or_detect_empty(message) do
    case cmd("git", ["commit", "-m", message]) do
      {:ok, _} ->
        :ok

      {:error, {output, _code}} = error ->
        if nothing_to_commit?(output), do: {:error, :no_changes}, else: error
    end
  end

  defp nothing_to_commit?(output), do: String.contains?(output, "nothing to commit")

  defp git_push(branch) do
    stderr("Pushing branch...")

    with {:ok, _} <- cmd("git", ["push", "-u", "origin", branch]) do
      :ok
    end
  end

  defp ensure_pr(issue, mode) do
    stderr("Opening pull request...")
    body = "Closes ##{issue.number}\n\nOpened automatically by `mix loop`."

    case cmd("gh", ["pr", "create", "--title", pr_title(issue, mode), "--body", body]) do
      {:ok, output} -> extract_pr_url(output)
      {:error, _} -> find_existing_pr()
    end
  end

  defp find_existing_pr do
    case cmd("gh", ["pr", "view", "--json", "url", "-q", ".url"]) do
      {:ok, url} -> {:ok, url}
      _error -> {:error, :no_pr}
    end
  end

  defp comment_issue(issue, body) do
    case cmd("gh", ["issue", "comment", Integer.to_string(issue.number), "--body", body]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # --- Decoding ---

  defp decode(json) do
    {:ok, :json.decode(json)}
  rescue
    _ -> :error
  end

  defp to_issue(obj) when is_map(obj) do
    %{
      number: Map.get(obj, "number"),
      title: string_or_empty(Map.get(obj, "title")),
      body: string_or_empty(Map.get(obj, "body")),
      labels: obj |> Map.get("labels", []) |> to_labels()
    }
  end

  defp to_labels(labels) when is_list(labels), do: Enum.flat_map(labels, &label_name/1)
  defp to_labels(_labels), do: []

  defp label_name(%{"name" => name}) when is_binary(name), do: [name]
  defp label_name(name) when is_binary(name), do: [name]
  defp label_name(_other), do: []

  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(_value), do: ""

  # --- Prompt fragments ---

  defp task_line(issue, :bug) do
    "Your task is to reproduce and fix the bug described in GitHub issue ##{issue.number}."
  end

  defp task_line(issue, :feature) do
    "Your task is to implement the feature described in GitHub issue ##{issue.number}."
  end

  defp tdd_note(:bug) do
    "Start by writing a test that reproduces the bug, then fix it until the test passes."
  end

  defp tdd_note(:feature) do
    "Write a failing test for the new behavior, then implement it until the test passes."
  end

  defp issue_body(%{body: body}) do
    case String.trim(body) do
      "" -> "(No description provided.)"
      trimmed -> trimmed
    end
  end

  defp branch_prefix(:bug), do: "fix"
  defp branch_prefix(:feature), do: "feature"

  defp title_prefix(:bug), do: "fix"
  defp title_prefix(:feature), do: "feat"

  defp mode_label(:bug), do: "bug"
  defp mode_label(:feature), do: "feature"

  # --- Errors ---

  defp handle_error({:error, :no_gh}) do
    stderr("gh CLI not found. Install it: https://cli.github.com/")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_claude}) do
    stderr("claude CLI not found. Install it: https://docs.claude.com/claude-code")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_readme}) do
    stderr("README.md not found")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_issues}) do
    stderr("No open issues found. Nothing to loop on!")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :invalid_json}) do
    stderr("Could not parse the issue data returned by gh.")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_changes}) do
    stderr("The agent produced no changes — nothing to commit. Leaving the branch as-is.")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_pr}) do
    stderr("Pushed the branch but could not open or find a PR. Open one manually.")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, :no_pr_url}) do
    stderr("Opened a PR but could not read its URL from the gh output.")
    exit({:shutdown, 1})
  end

  defp handle_error({:error, {output, code}}) do
    stderr("Command failed (exit #{code}):\n#{output}")
    exit({:shutdown, 1})
  end

  defp stderr(msg), do: IO.puts(:stderr, msg)
end
