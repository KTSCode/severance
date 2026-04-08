# Severance

Shared project conventions for all AI coding agents.

## Build & Test
- `mix deps.get` — fetch dependencies
- `mix compile --warnings-as-errors` — compile with strict warnings
- `mix test` — run all tests
- `mix test path/to/test.exs` — run a single test file
- `mix credo --strict` — lint
- `mix dialyzer` — typecheck (slow first run, builds PLT)
- `mix format` — format code
- `mix quality` — run all quality checks (compile, format, credo, dialyzer, tests)

## Stack
- Elixir 1.19+ / OTP 28+
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
- Format with `mix format` after changes
- Lint with `mix credo --strict`
- Property-based tests use PropCheck
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
- Update `CHANGELOG.md` under `## [Unreleased]` when a branch introduces user-facing changes
- Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format
- Use subsections: `### Added`, `### Changed`, `### Fixed`, `### Removed`
- Write entries from the user's perspective, not the developer's

## Documentation Lifecycle
- Superseded specs move to `docs/archive/`
- Files keep their original names (date prefix provides chronological ordering)
- Agents ignore `docs/archive/` during routine sessions
- Never delete specs — archive for historical context
