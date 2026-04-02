# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]
- Fix sev update to replace correct binary and keep plist current

## [0.2.0] -- 2026-04-01

### Added
- `sev update` self-update command via GitHub Releases API
- `mix tag` task for version bumping, changelog finalization, and release tagging

### Fixed
- Escape AppleScript string interpolation to prevent injection via tmux pane names
- Handle invalid `--shutdown-time` input gracefully instead of crashing
- Remove duplicate `SEVERANCE_SHUTDOWN_TIME` parsing from `runtime.exs` that crashed on `HH:MM` format
- Fix typos in notification messages ("decided" → "decide", "Save you work" → "Save your work")
- Remove unused `pending_changes?/1` function
- Align default shutdown time in `config.exs` with `config.ex` and README (16:30 → 17:00)
- Scope `git add` in `mix todo --done` to README.md and CHANGELOG.md instead of entire repo
- Scope `check_todo_in_readme` and `prune_checked_todos` to `## TODO` section only
- Prevent `insert_under_added` from crossing changelog subsection boundaries
- Use tab delimiter in tmux pane queries to handle paths with spaces
- Add fallback clause to `target_name/1` for unsupported architectures
- Handle `{:badrpc, reason}` in CLI RPC helpers (`run_overtime`, `run_stop`)
- Replace bare `rescue` in `check_status_right_length` with `Integer.parse/1`
- Pass stale threshold to notification message instead of hardcoding "15m"
- Simplify `tick/1` to `tick/0` (return value was unused)
- Document config file code execution in `Severance.Config` moduledoc

## [0.1.0] — 2026-03-29

### Added
- Countdown GenServer with phase state machine and escalating shutdown warnings
- macOS notifications via `osascript` with overtime protocol
- Tmux status bar integration and stale pane detection
- CLI with arg parsing and OTP RPC (`start`, `stop`, `overtime`, `init`)
- Burrito-wrapped standalone binary for macOS (ARM64 and x86_64)
- LaunchAgent plist for login startup
- Config file support with automatic system timezone inference
- Late start handling with overtime burst
- Exponential backoff on shutdown retries
- `mix todo` task for AI-driven TODO workflow
- CI and release GitHub Actions workflows
- Agent-agnostic AGENTS.md project conventions
