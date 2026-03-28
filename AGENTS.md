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

## Stack
- Elixir 1.19+ / OTP 28+
- macOS only (uses `osascript` for notifications and shutdown)
- tmux (status bar integration and stale pane detection)

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
1. **Plan** — `docs/plans/<feature>.md`
1. **Execute** — one phase at a time

## Documentation Lifecycle
- Completed plans move to `docs/archive/`
- Superseded specs move to `docs/archive/`
- Files keep their original names (date prefix provides chronological ordering)
- Agents ignore `docs/archive/` during routine sessions
- Never delete plans or specs — archive for historical context
