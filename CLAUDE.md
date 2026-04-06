# Severance — Claude Code

Read **AGENTS.md** for project conventions, build commands, and workflow.

## Hooks
- Pre-commit checks configured in `.claude/settings.local.json`

## MCP Servers
Three MCP servers provide runtime introspection during development:

- **tidewave** — eval/docs in mix sessions. Start with `mix tidewave` before agent sessions
- **erl_dist_mcp** — deep OTP introspection. Connects to running `severance@hostname` daemon
- **hex-mcp** — hex package versions. Always available (hosted service)

Configuration lives in `.mcp.json`.
