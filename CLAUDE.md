# Severance — Claude Code

Read **AGENTS.md** for project conventions, build commands, and workflow.

## Documentation

`docs/architecture.md` is a living current-state doc — not a point-in-time
spec. When a change alters the supervision tree, the countdown state
machine, config resolution, the RPC seam, or the set of modules, update it
in the same PR. See AGENTS.md → Documentation Lifecycle for the full rule.

## Hooks
- Agent pre-commit gate in `.claude/settings.json` runs `mix quality --profile quick` before `git commit`
- Git hooks in `.githooks/` (via `core.hooksPath`): pre-commit runs `mix quality --profile quick`, pre-push runs full `mix quality` including the release smoke stage

## MCP Servers
Three MCP servers provide runtime introspection during development:

- **tidewave** — eval/docs in mix sessions. Start with `mix tidewave` before agent sessions
- **erl_dist_mcp** — deep OTP introspection. Connects to running `severance@hostname` daemon
- **hex-mcp** — hex package versions. Always available (hosted service)

Configuration lives in `.mcp.json`.
