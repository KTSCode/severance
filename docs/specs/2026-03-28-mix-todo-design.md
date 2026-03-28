# Mix Todo Task Design

## Context

Time blindness and hyperfocus make it hard to stop working — and hard to
*start* the right work. The README TODO list captures what needs doing, but
picking up the next item still requires manual context-gathering and branch
setup. This task automates the bookends of that workflow so an AI coding
agent can go from zero to PR with a single pipe.

The goal: `mix todo | claude` (or `| codex`, `| gemini-cli`) picks up the
next TODO, sets up a branch, feeds the agent a complete prompt, and
`mix todo --done` finalizes the work into a PR.

## Design

### `mix todo` (no flags)

1. Parse `README.md` for the `## TODO` section
2. Find the first unchecked item (`- [ ]`)
3. No unchecked items → stderr message, exit 1
4. `.todo-current` already exists → stderr error ("Already working on:
   \<text\>. Run `mix todo --done` or delete `.todo-current` to reset."),
   exit 1
5. Check that `gh` CLI is installed → stderr error if missing, exit 1
6. Create branch `todo/<slug>` off main
7. Write the TODO text to `.todo-current`
8. Stdout: agent prompt containing:
   - The specific TODO item
   - The full README.md contents (architecture, conventions, build
     commands — everything the agent needs)
   - Instructions: read the codebase, use TDD, implement the feature,
     run `mix todo --done` when complete

Status messages ("Creating branch...", etc.) go to stderr so they don't
pollute the pipe.

### `mix todo --done`

1. Read `.todo-current` — if missing, stderr error, exit 1
2. Check that `gh` CLI is installed → stderr error if missing, exit 1
3. In `README.md`: check the box (`- [x]`) for the matching item
4. Count checked TODOs — if more than 3, remove the oldest (topmost in
   the list)
5. Add entry to `CHANGELOG.md` under `## [Unreleased]` / `### Added`
   - If `CHANGELOG.md` doesn't exist, create it with Keep a Changelog
     header
   - If `## [Unreleased]` exists, append to it
6. Commit `README.md` + `CHANGELOG.md`
7. Push the branch
8. Open PR via `gh pr create` (title from TODO text, minimal placeholder
   body)
9. Stdout: instructions telling the agent to:
   - Update the PR body (`gh pr edit`) with a clear description of what
     was implemented and why
   - Review the `CHANGELOG.md` entry and pick the correct category
     (Added / Changed / Fixed / Removed)
   - If the category changed, amend the commit and force-push
10. Delete `.todo-current`

### Guard Rails

- **Double-start protection:** `mix todo` refuses to run if
  `.todo-current` exists
- **`gh` dependency check:** both paths check for `gh` early and fail
  with a clear install link
- **Idempotent `--done`:** second run exits 1 because `.todo-current` is
  gone — safe, no damage
- **Clean exit:** errors use `exit({:shutdown, 1})` for non-zero status
  without stacktraces

## Files

| File | Action | Purpose |
|---|---|---|
| `lib/mix/tasks/todo.ex` | Create | The Mix task — single module |
| `test/mix/tasks/todo_test.exs` | Create | Tests for all pure functions |
| `.gitignore` | Edit | Add `.todo-current` |
| `CHANGELOG.md` | Created at runtime | By `mix todo --done` if missing |

## Module Design

Single module: `Mix.Tasks.Todo`

### Pure functions (unit-testable, async: true)

| Function | Signature | Purpose |
|---|---|---|
| `parse_todo_section/1` | `String.t() → {:ok, [todo_item]} \| {:error, :no_todo_section}` | Line-by-line scan of README, scoped to `## TODO` |
| `first_unchecked/1` | `[todo_item] → {:ok, todo_item} \| {:error, :all_done}` | First item where `checked: false` |
| `slugify/1` | `String.t() → String.t()` | Downcase, replace non-alnum with `-`, trim, truncate to 60 chars |
| `check_todo_in_readme/2` | `String.t(), String.t() → {:ok, String.t()}` | Replace `- [ ]` with `- [x]` for matching item |
| `prune_checked_todos/1` | `String.t() → {:ok, String.t()}` | Remove oldest checked if count > 3 |
| `new_changelog/1` | `String.t() → String.t()` | Generate fresh CHANGELOG.md with entry |
| `add_changelog_entry/2` | `String.t(), String.t() → String.t()` | Insert entry under `## [Unreleased]` |
| `build_prompt/2` | `String.t(), String.t() → String.t()` | Agent prompt with TODO + README + instructions |
| `build_done_prompt/2` | `String.t(), String.t() → String.t()` | Post-done instructions with PR URL |

`todo_item` type: `%{checked: boolean(), text: String.t(), line_number: pos_integer()}`

### Side-effecting helpers

| Function | Purpose |
|---|---|
| `cmd/2` | Wraps `System.cmd/3` → `{:ok, output} \| {:error, {output, code}}` |
| `check_gh_installed/0` | `System.find_executable("gh")` check |
| `create_branch/1` | `git checkout main && git pull && git checkout -b todo/<slug>` |
| `git_commit/1` | `git add README.md CHANGELOG.md && git commit` |
| `git_push/0` | `git push -u origin HEAD` |
| `create_pr/1` | `gh pr create` — returns `{:ok, pr_url}` |

### Entry point

```elixir
def run(["--done"]), do: done()
def run([]), do: start()
def run(_), do: Mix.shell().error("Usage: mix todo [--done]")
```

Both `start/0` and `done/0` use `with` chains that delegate to
`handle_error/1` on failure. Each error clause prints a specific message
to stderr and exits with status 1.

## CHANGELOG Format

Keep a Changelog. Fresh file template:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- <TODO item text>
```

`mix todo --done` always writes under `### Added` as a placeholder. The
agent prompt instructs the agent to recategorize if appropriate (Changed,
Fixed, Removed).

## Test Strategy

All pure functions tested with `async: true` in describe blocks. Key
coverage:

- **`parse_todo_section/1`**: mixed items, no section, empty section,
  stops at next heading, preserves line numbers
- **`first_unchecked/1`**: mixed list, all checked, empty list
- **`slugify/1`**: spaces, special chars, leading/trailing hyphens,
  truncation, already-clean strings
- **`check_todo_in_readme/2`**: checks correct item, skips already-checked
  duplicates
- **`prune_checked_todos/1`**: removes topmost checked when > 3, no-op
  at ≤ 3, leaves unchecked alone
- **`add_changelog_entry/2`**: existing unreleased section, missing
  section, creates Added subsection
- **`build_prompt/2`**: contains TODO text, README, TDD instructions,
  `mix todo --done` instruction

File I/O functions accept a `root` parameter (defaulting to `File.cwd!()`)
following the pattern in `Severance.Config.read/1`. This enables async
tests with isolated temp directories — no `File.cd!` needed.

Git/gh commands are not unit-tested. The pure functions handle all logic;
shell commands are thin wrappers tested via manual integration.

## Prompt Templates

### `mix todo` stdout

```
You are working on the Severance project. Your task is to implement the
following TODO item:

> <TODO TEXT>

## Project Context

<FULL README.md CONTENTS>

## Instructions

1. Read the codebase to understand the architecture and existing patterns.
2. Follow TDD: write a failing test first, then implement until it passes.
3. Run `mix format` after changes.
4. Run `mix credo --strict` and fix any issues.
5. Run `mix test` to verify everything passes.
6. When implementation is complete and all tests pass, run:
   mix todo --done
```

### `mix todo --done` stdout

```
TODO item completed. PR created: <PR_URL>

## Remaining Steps

1. Update the PR description with a clear summary of what was implemented
   and why. Use `gh pr edit <PR_URL> --body "..."` to set the body.
2. Review CHANGELOG.md — the entry was added under "### Added" as a
   placeholder. Pick the correct category: Added, Changed, Fixed, or
   Removed. If you change the category, commit and push.
```
