# Code Audit — 2026-03-30

Re-checked against the current codebase on 2026-03-30.

Status of the earlier draft:
- Most original findings still hold as written.
- The `slugify/1` item was overstated: there is spec drift in `docs/specs/2026-03-28-mix-todo-design.md`, but there is no corresponding implementation or test in the codebase. That note is informational only, not a recommendation to implement an older design doc.

Verification run during this audit:
- `mix compile --warnings-as-errors` passes
- `mix test` passes (`121 tests, 0 failures`)

The passing test suite does not cover several edge cases below.

## High Severity

### Command injection in `osascript` notifications
`lib/severance/system/real.ex:14-18` interpolates `title`, `message`, and
`sound` directly into an AppleScript string. `lib/severance/notifier.ex:102-107`
passes tmux pane names and paths through that code path. A pane name or path
containing quotes can break out of the string and alter the script.

Suggested fix: escape interpolated values correctly, or avoid string
interpolation entirely by passing separate `-e` fragments / arguments.

### `SEVERANCE_SHUTDOWN_TIME` in `runtime.exs` crashes on the documented `HH:MM` format
`config/runtime.exs:3-4` calls `Time.from_iso8601!/1` directly on the env var.
The README documents `SEVERANCE_SHUTDOWN_TIME=16:30 sev` at
`README.md:124-126`, but `Time.from_iso8601!("16:30")` raises
`:invalid_format`. That means the documented env-var form can crash boot before
`Severance.Application.resolve_config/2` gets a chance to apply its more
lenient parsing.

Suggested fix: remove the duplicate parse from `runtime.exs`, or normalize
`HH:MM` to `HH:MM:SS` and handle invalid input without `!`.

### `mix todo --done` can change README content outside the `## TODO` section
Two helpers operate on the whole README instead of the parsed TODO block:

- `lib/mix/tasks/todo.ex:62-78` (`check_todo_in_readme/2`) checks the first
  matching `- [ ] ...` line anywhere in the file.
- `lib/mix/tasks/todo.ex:84-108` (`prune_checked_todos/1`) removes checked
  checklist items globally once there are more than three.

If the same checklist text appears outside `## TODO`, or if the README contains
other checked lists, `mix todo --done` can mark or delete the wrong lines.

Suggested fix: scope both operations to the parsed TODO section boundaries
instead of scanning the entire file.

### `mix todo --done` stages unrelated files with `git add -A`
`lib/mix/tasks/todo.ex:415-420` stages the entire repo before committing. That
can silently pull unrelated local edits, generated files, or sensitive
untracked files into the TODO completion commit.

Suggested fix: stage only the explicit files the task modifies
(`README.md`, `CHANGELOG.md`, `.todo-current` removal, and any known generated
artifacts if applicable).

## Medium Severity

### `--shutdown-time` crashes on invalid input
`lib/severance/cli.ex:52-55` pattern matches on
`{:ok, time} = Time.from_iso8601(time_str <> ":00")`. Bad input like
`sev --shutdown-time lol` raises `MatchError` instead of returning a user-facing
error.

Suggested fix: handle `{:error, reason}` explicitly and print a usage error.

### Default shutdown time is inconsistent across the repo
Three different defaults exist:

- `config/config.exs:3-6` sets compiled default `~T[16:30:00]`
- `lib/severance/config.ex:10-13` writes default config `"17:00"`
- `README.md:21-22` documents default `5:00 PM`

Behavior therefore depends on whether the user has run `sev init`, and the docs
do not match the no-config runtime behavior.

Suggested fix: define the default once and derive both runtime config and
generated config from that single source.

### Stale tmux pane parsing breaks on spaces in window names or paths
`lib/severance/tmux.ex:49-57` asks tmux for a space-delimited line, and
`lib/severance/tmux.ex:72-76` parses each line with `String.split(line, " ")`
expecting exactly `[pane, path, activity]`.

That assumption fails for:
- tmux window names containing spaces
- pane paths containing spaces

Those panes are silently dropped from stale-pane detection.

Suggested fix: emit a delimiter that cannot appear in the fields (for example a
tab), or split from the right in a way that preserves pane/path content.

### `target_name/1` has no fallback clause
`lib/severance/updater.ex:88-93` only handles `aarch64` and `x86_64`. Any other
architecture raises `CondClauseError` before the updater can return a normal
error.

Suggested fix: add a fallback that returns a tagged error for unsupported
architectures.

### CLI RPC helpers ignore remote call failures
`lib/severance/cli.ex:83-86` and `lib/severance/cli.ex:100-103` call `:rpc.call`
but discard its return value and always print success if the node connection was
established. If the remote call returns `{:badrpc, reason}`, the CLI still
reports success.

Suggested fix: pattern match on the RPC result and surface failures instead of
always returning `:ok`.

### `insert_under_added/2` does not respect changelog subsection boundaries
`lib/mix/tasks/todo.ex:267-285` keeps scanning after `### Added` for any `- `
line, even after the next changelog subsection heading such as `### Fixed`.
Entries can therefore be inserted under the wrong subsection.

Suggested fix: stop scanning at the next `### ` heading.

## Low Severity

### Trusted-code execution in user config should be documented more explicitly
`lib/severance/config.ex:3-8` and `lib/severance/config.ex:47-49` use
`Code.eval_file/1` on `~/.config/severance/config.exs`. Because the file is
user-owned, this is an acceptable trust boundary, but the docs should describe
it as trusted code execution rather than plain data loading.

Suggested fix: document the config file as executable Elixir code.

### Typo in overtime 1-minute notification
`lib/severance/notifier.ex:59-61` says `"1 minute left to decided to be a
person and stop."`

Suggested fix: change `"decided"` to `"decide"`.

### Typo in stale pane notification
`lib/severance/notifier.ex:103-105` says `"Save you work"`.

Suggested fix: change `"you"` to `"your"`.

### `pending_changes?/1` is defined and tested but unused
`lib/mix/tasks/todo.ex:315-321` is covered by tests in
`test/mix/tasks/todo_test.exs:315-329`, but nothing in `start/1` or `done/1`
calls it.

Suggested fix: either remove it and its tests, or wire it into a real guard.

### `slugify/1` exists only in the design doc
`docs/specs/2026-03-28-mix-todo-design.md:91,154` mentions a `slugify/1`
helper, but there is no corresponding implementation in `lib/mix/tasks/todo.ex`
and no matching test in `test/mix/tasks/todo_test.exs`.

Suggested fix: none in code. Treat this as historical spec drift unless that
spec is still intended to be active.

### Duplicate parsing of `SEVERANCE_SHUTDOWN_TIME`
The shutdown-time env var is parsed in two places:

- `config/runtime.exs:3-4`
- `lib/severance/application.ex:109-114`

Even aside from the crash in `runtime.exs`, this duplication means Layer 3
effectively reparses and overrides work already done during boot.

Suggested fix: keep env-var parsing in one place only.

### Hardcoded stale-threshold text in the notification body
`lib/severance/notifier.ex:103-105` says `"No activity in 15m"` while the real
threshold lives in `lib/severance/countdown.ex:24`.

Suggested fix: pass the threshold through from the countdown logic or centralize
the constant.

### Bare rescue in `check_status_right_length/0`
`lib/severance/init.ex:122-139` rescues all exceptions with `rescue _ ->`.
That hides the specific failure mode and makes unexpected errors harder to
debug.

Suggested fix: rescue only the concrete exceptions you expect.

### `tick/1` returns a value that callers ignore
`lib/severance/countdown.ex:227-229` returns `state`, but
`lib/severance/countdown.ex:125-129` calls it only for its side effect.

Suggested fix: return `:ok` or inline the `send/2` call.
