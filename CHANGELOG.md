# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
