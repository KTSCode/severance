# Severance

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
