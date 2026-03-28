# Agent-Agnostic Project Configuration

**Date:** 2026-03-28
**Status:** Draft

## Problem
The project uses Claude Code-specific conventions (CLAUDE.md as the sole
conventions file, docs/superpowers/ for plans and specs) that lock out
other AI coding agents (Gemini CLI, Codex, etc.).

## Goal
Create an agent-agnostic layer so any AI coding agent can work with the
project, without removing existing Claude Code functionality.

## Design

### Hub-and-spoke model
AGENTS.md is the hub containing all shared project conventions. Agent-specific
files (CLAUDE.md, future GEMINI.md) are thin spokes that point to the hub
and add only agent-specific configuration.

- **AGENTS.md** — build commands, stack, architecture, conventions, workflow,
  documentation lifecycle rules
- **CLAUDE.md** — pointer to AGENTS.md + MCP server config + hooks documentation
- **No GEMINI.md** — AGENTS.md is the universal fallback. Add a thin pointer
  later if Gemini-specific config is needed.

### Directory restructure
```
docs/
├── plans/
│   ├── README.md
│   └── 2026-03-26-severance-plan.md   (moved from superpowers)
├── research/
│   └── README.md
├── specs/                              (new)
│   ├── README.md
│   ├── 2026-03-26-severance-design.md (moved from superpowers)
│   └── 2026-03-28-mix-todo-design.md  (moved from superpowers)
└── archive/                            (new)
    └── README.md
```

`docs/superpowers/` is deleted entirely after relocation.

### AGENTS.md content
Consolidates current CLAUDE.md content plus workflow instructions from
README.md, organized as:
1. Build & Test — all mix commands
1. Stack — Elixir/OTP versions, macOS, tmux
1. Architecture — daemon, LaunchAgent, BEAM RPC
1. Conventions — formatting, linting, TDD, PropCheck
1. Workflow — research/plan/execute flow with directory references
1. Documentation Lifecycle — archiving rules for completed work

### CLAUDE.md content (rewritten)
Thin pointer (~10 lines):
1. Instruction to read AGENTS.md for project conventions
1. MCP section noting tidewave in `.mcp.json`
1. Hooks section referencing `.claude/settings.local.json`

### README.md changes (lines 154-167)
Updated AI-assisted workflow section:
- References AGENTS.md first as the primary conventions file
- Lists CLAUDE.md second with scope note "Claude Code-specific configuration"
- Keeps tidewave and dialyxir references (project dependencies, not agent-specific)

### mix.exs change (line 16)
`usage_rules` target changes from `"CLAUDE.md"` to `"AGENTS.md"` so future
dependency usage rules are synced into the shared conventions file.

### Documentation lifecycle rules (in AGENTS.md)
- When a plan's work is fully merged, move it to `docs/archive/`
- When a spec is superseded, move it to `docs/archive/`
- Files keep their original names (date prefix provides chronological ordering)
- Agents should ignore `docs/archive/` during routine sessions
- Never delete plans or specs — archive for historical context

## Files changed

### New
- `AGENTS.md`
- `docs/specs/README.md`
- `docs/archive/README.md`

### Modified
- `CLAUDE.md` (rewritten to thin pointer)
- `README.md` (lines 154-167)
- `mix.exs` (line 16)

### Moved (git mv)
- `docs/superpowers/plans/2026-03-26-severance-plan.md` → `docs/plans/`
- `docs/superpowers/specs/2026-03-26-severance-design.md` → `docs/specs/`
- `docs/superpowers/specs/2026-03-28-mix-todo-design.md` → `docs/specs/`

### Deleted
- `docs/superpowers/` (entire directory after moves)

## Verification
- `mix compile --warnings-as-errors`
- `mix test`
- `mix credo --strict`
- `mix format --check-formatted`
- AGENTS.md stands alone as a complete conventions document
- CLAUDE.md first instruction points to AGENTS.md
