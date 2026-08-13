# Severance

Shared project conventions for all AI coding agents.

## Build & Test
- `mix deps.get` — fetch dependencies
- `mix quality` — full quality suite (format, compile, credo, dialyzer, doctor, tests + coverage, release smoke)
- `mix quality --profile quick` — fast iteration (skips dialyzer, coverage enforcement, and the release smoke stage)
- `mix test path/to/test.exs` — run a single test file
- `mix credo --strict` — lint a single file or full project
- `mix dialyzer` — typecheck (slow first run, builds PLT)
- `mix format` — format code

## Stack
- Elixir 1.20+ / OTP 29+
- macOS only (uses `osascript` for notifications and shutdown)
- tmux (status bar integration and stale pane detection)

## MCP Tools
Three MCP servers provide runtime introspection (configured in `.mcp.json`):
- **tidewave** — eval/docs in mix sessions. Start with `mix tidewave` before using
- **erl_dist_mcp** — deep OTP introspection of the running daemon
- **hex-mcp** — hex package version queries (hosted service, always available)

## Architecture
Background daemon that enforces daily computer shutdown with escalating warnings.
Runs as a LaunchAgent, communicates via BEAM RPC for overtime protocol.

## Conventions
- Git hooks (in `.githooks/`, wired via `core.hooksPath`): pre-commit runs `mix quality --profile quick`, pre-push runs full `mix quality` including the release smoke stage (`bin/checks/release_smoke.sh`)
- Format with `mix format` after changes
- Lint with `mix credo --strict`
- TDD: write failing tests first, then implement. No exceptions.

## Workflow
Each coding session starts fresh and relies on durable repo files rather
than chat history. Small, well-understood changes go straight to code.
For anything larger:

1. **Research** — `docs/research/<feature>.md`
1. **Spec** — `docs/specs/<feature>.md`
1. **Plan** — lives in the PR description (see Pull Requests below), not committed to the repo
1. **Execute** — one phase at a time

## Pull Requests
- When a PR was built from an implementation plan, include the plan in the PR description inside a collapsed `<details>` block
- The summary and test plan go above the fold; the plan goes below
- Format:
  ```markdown
  ## Summary
  - bullet points

  ## Test plan
  - [x] what was tested

  <details>
  <summary>Implementation Plan</summary>

  (full plan content here)

  </details>
  ```

## Changelog
- Do not edit `CHANGELOG.md` during TODO work — finalize with `mix todo --done "<accurate description>"`. That description rewrites the item's TODO line in README.md and becomes the `## [Unreleased]` entry
- `mix todo --done` is idempotent and safe to re-run: it skips an already-checked TODO, a duplicate changelog entry, an empty commit, and an already-merged PR
- For changes made outside the `mix todo` flow, add the entry by hand
- Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format
- Use subsections: `### Added`, `### Changed`, `### Fixed`, `### Removed`
- Write entries from the user's perspective, not the developer's

## Documentation Lifecycle
Living docs track the current system and MUST stay current — update them in
the same PR as the change that affects them. A PR that leaves one describing
a system that no longer exists is incomplete.
- `docs/architecture.md` — current-state architecture. Update when a change
  alters the supervision tree, the countdown state machine, config
  resolution, the RPC seam, or the set of modules
- `README.md` and `docs/configuration.md` — user-facing usage and the
  publisher contract

Point-in-time docs (`docs/specs/`, `docs/research/`) are snapshots, not
living docs:
- Superseded specs move to `docs/archive/`
- Files keep their original names (date prefix provides chronological ordering)
- Agents ignore `docs/archive/` during routine sessions
- Never delete specs — archive for historical context
