---
name: tidewave-mcp
description: Use when developing features, debugging, or exploring the Severance codebase with tidewave MCP tools. Applies when you need runtime introspection, live evaluation, or dependency documentation during development.
---

# Tidewave MCP

Runtime introspection for the Severance Elixir application via MCP.

## Starting the Server

Tidewave runs as a `mix tidewave` process in a tmux pane. Use the `tmux` skill to manage it.

1. Check existing panes for a running `mix tidewave` process
1. If none exists, start one in a new pane: `mix tidewave`
1. Wait for `Bandit is running on port 4000` before using MCP tools

The alias starts Bandit serving the Tidewave Plug on port 4000. The MCP connection is configured in `.mcp.json`.

## Stopping the Server

When introspection is no longer needed:

1. Send `Ctrl+C` to the `mix tidewave` pane — this enters BREAK mode
1. Send `a` to abort the process
1. Optionally close the pane

Stop the server when you're done with runtime introspection to free the port.

## Available Tools

| Tool | Purpose | Use when |
|------|---------|----------|
| `project_eval` | Evaluate Elixir code in app context | Testing functions, inspecting state, checking process trees, exploring modules |
| `get_source_location` | Find source file for module/function | Navigating to code — faster than grepping, works for deps too |
| `get_docs` | Fetch `@doc`/`@moduledoc` | Reading docs for any module or function, including deps |
| `search_package_docs` | Search hex docs for project deps | Learning how a dependency works without leaving the session |
| `get_logs` | Tail application logs with filtering | Debugging errors, checking request logs, filtering by level or regex |

## Preferred Tool Selection

- **Find source of a known module/function** — `get_source_location` over Grep
- **Check what a module exports** — `project_eval` with `exports(ModuleName)`
- **Understand a function's behavior** — `get_docs` first, then `project_eval` to test
- **Explore a dependency's API** — `search_package_docs` then `get_docs` for specifics
- **Debug runtime issues** — `get_logs` to find errors, `project_eval` to inspect state

## Common Patterns

```elixir
# List a module's public API
exports(Severance.SomeModule)

# Check supervision tree
Supervisor.which_children(Severance.Supervisor)

# Inspect GenServer state
:sys.get_state(pid_or_name)

# Check process info
Process.info(pid, [:message_queue_len, :memory, :status])

# List registered processes
Process.registered()
```

## Do NOT

- Use `project_eval` to modify production state — read-only introspection only
- Assume tidewave is running without checking first
- Use Bash to evaluate Elixir code when `project_eval` is available
