# Mix Loop Task Design

## Context

`mix todo` and `mix bump` already prove out a pattern: a Mix task gathers
context and hands a coding agent a complete, structured prompt. But both
still rely on a human (or a separate agent process) to actually do the
work and to keep re-running until the change is good.

`mix loop` closes that gap for issue-driven work. It is an **autonomous,
self-driving loop**: it picks a GitHub issue, classifies it as a feature
or a bug, drives `claude` headless to implement (or fix) it, verifies the
result with `mix quality`, feeds any failure back into the next attempt,
and repeats until the suite is green or a max-iteration budget is spent.
On success it commits, pushes, opens a PR that closes the issue, and
comments the outcome back on the issue.

The goal: `mix loop` (optionally `--issue N`) takes an issue from backlog
to green-and-pushed with no human in the inner loop, while leaving the PR
for human review rather than auto-merging.

## Design

### `mix loop [--issue N] [--label L] [--max M] [--full]`

1. Check `gh` and `claude` are installed → stderr error if missing, exit 1.
2. Read `README.md` for project context (fed to the agent like `mix todo`).
3. Select the issue:
   - `--issue N` → `gh issue view N --json number,title,body,labels`.
   - otherwise → `gh issue list --state open --json ... [--label L]`,
     take the first open issue.
   - no open issues → stderr message, exit 1.
4. Classify the issue from its labels: any of `bug`, `fix`, `defect`,
   `regression`, `debug` → `:bug`; otherwise `:feature`. This selects the
   prompt framing (a bug is reproduced with a failing test first; a
   feature is built test-first).
5. Create/checkout a working branch `feature/<n>-<slug>` or
   `fix/<n>-<slug>` off `main`.
6. Run the iteration loop, up to `--max` (default 5):
   - Iteration 1 → `build_initial_prompt` (issue + README + instructions).
   - Later iterations → `build_retry_prompt` (issue + the tail of the
     previous `mix quality` output + "fix without reverting progress").
   - Invoke `claude` headless with the prompt
     (`claude -p <prompt> --dangerously-skip-permissions`) so it can edit
     files autonomously.
   - Run `mix quality` (`--quick` by default, full with `--full`).
   - `quality_passed?` (exit 0) → done. Else, if iterations remain →
     retry with the failure tail; if budget spent → exhausted.
7. Outcome:
   - **done** → `git add -A` + commit (`feat:`/`fix:` subject, `Closes #N`
     body), push the branch, `gh pr create` (falling back to the existing
     PR), comment the summary + PR URL on the issue, print the summary.
   - **exhausted** → leave the branch in place for manual review, comment
     the failure summary on the issue, print it, exit 1.

Status messages ("Iteration 2/5: running mix quality...") go to stderr so
stdout stays a clean summary.

### Guard rails

- **Tool checks:** both `gh` and `claude` are probed up front with a clear
  message and a non-zero exit if missing.
- **Bounded:** the loop can never run forever — `--max` caps attempts and
  `should_continue?/3` is the single decision point.
- **Non-destructive on failure:** an exhausted loop never force-anything;
  it leaves the branch and surfaces the failing output.
- **No auto-merge:** unlike `mix todo`, `mix loop` opens a PR for human
  review rather than merging it.
- **Clean exit:** errors use `exit({:shutdown, 1})` — non-zero status, no
  stacktrace.

## Files

| File | Action | Purpose |
|---|---|---|
| `lib/mix/tasks/loop.ex` | Create | The Mix task — single module |
| `test/mix/tasks/loop_test.exs` | Create | Tests for all pure functions |
| `CHANGELOG.md` | Edit | `### Added` entry |
| `README.md` | Edit | Document the command under Development |

## Module Design

Single module: `Mix.Tasks.Loop`.

`issue` type: `%{number: integer(), title: String.t(), body: String.t(),
labels: [String.t()]}`. `mode` type: `:feature | :bug`.

### Pure functions (unit-testable, `async: true`)

| Function | Signature | Purpose |
|---|---|---|
| `parse_issues/1` | `String.t() → {:ok, [issue]} \| {:error, :invalid_json}` | Decode a `gh issue list --json` array |
| `parse_issue/1` | `String.t() → {:ok, issue} \| {:error, :invalid_json}` | Decode a `gh issue view --json` object |
| `first_open_issue/1` | `[issue] → {:ok, issue} \| {:error, :no_issues}` | First issue in the list |
| `classify_issue/1` | `issue → :feature \| :bug` | Label-based feature/bug split |
| `slugify/1` | `String.t() → String.t()` | Branch-safe slug |
| `build_branch_name/2` | `issue, mode → String.t()` | `feature/<n>-<slug>` / `fix/<n>-<slug>` |
| `pr_title/2` | `issue, mode → String.t()` | `feat:`/`fix:` subject line |
| `commit_message/2` | `issue, mode → String.t()` | Subject + `Closes #N` body |
| `build_initial_prompt/3` | `issue, mode, readme → String.t()` | First-attempt agent prompt |
| `build_retry_prompt/5` | `issue, mode, failure, iteration, max → String.t()` | Retry prompt with failure tail |
| `summarize_failure/2` | `String.t(), pos_integer() → String.t()` | Keep the last N lines of output |
| `quality_passed?/1` | `integer() → boolean()` | Exit code 0 |
| `should_continue?/3` | `boolean(), pos_integer(), pos_integer() → :done \| :retry \| :exhausted` | Loop decision |
| `claude_args/1` | `String.t() → [String.t()]` | Headless `claude` argv |
| `build_summary/4` | `issue, mode, :done \| :exhausted, integer() → String.t()` | Final report / issue comment |
| `extract_pr_url/1` | `String.t() → {:ok, String.t()} \| {:error, :no_pr_url}` | Pull the PR URL from `gh pr create` output |

### Side-effecting helpers

`cmd/2` wraps `System.cmd/3`; `check_gh_installed/0` and
`check_claude_installed/0` probe the tools; `fetch_issue/1` runs the `gh`
queries; `run_claude/1` and `run_quality/1` shell out per iteration;
`checkout_branch/1`, `git_commit/2`, `git_push/1`, `create_pr/2`, and
`comment_issue/2` finalize. Per project convention, git/gh/claude shell
commands are not unit-tested — the pure functions hold all the logic.

### Entry point

```elixir
def run(argv) do
  {opts, _, _} = OptionParser.parse(argv, strict: [...])
  loop(File.cwd!(), opts)
end
```

`loop/2` is a `with` chain delegating to `handle_error/1`, mirroring
`mix todo`.

## JSON decoding

Issues are decoded with OTP's built-in `:json` module (Severance targets
OTP 29+), wrapped so malformed input returns `{:error, :invalid_json}`
instead of raising. JSON `null` bodies are coerced to `""`.

## Test strategy

All pure functions tested with `async: true`. Side-effecting git/gh/claude
wrappers are exercised manually, consistent with `mix todo`.
