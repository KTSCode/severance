# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Add a current-state architecture doc and centralize countdown phase definitions in a single Severance.Phase module

## [0.18.0] -- 2026-06-08

### Added

- Add sev upgrade as an alias for sev update
- Add research doc cataloging ways past the macOS interrupted-shutdown dialog
- Add research doc on Do Not Disturb control
- Reset the daemon at midnight as a fresh day, so overtime is a single-day opt-out and the next day's shutdown is enforced again

## [0.17.0] -- 2026-06-04

### Added

- `sev help` prints top-level usage, aliasing `sev --help`
- Update elixir verison to 1.20 with the latest OTP
- Add `sev help --agent`, a machine-readable usage reference for LLM agents covering all commands, configuration keys and defaults, the publisher contract, and task-oriented setup recipes

### Changed

- `mix todo --done "<description>"` now takes an optional description that rewrites the item's TODO line and becomes the `[Unreleased]` CHANGELOG entry, replacing the verbatim TODO text
- `mix todo --done` is now idempotent and fails gracefully — re-running skips an already-checked TODO, a duplicate changelog entry, an empty commit, and an already-merged PR

## [0.16.0] -- 2026-06-04

### Changed

- CLI argument parsing now uses [CliMate](https://hexdocs.pm/cli_mate), replacing the hand-rolled `OptionParser` clauses
- `sev status <publisher>` debug invocation switched from a dynamic `--<publisher-name>` flag to a positional argument (`--teardown` still toggles teardown mode)
- `sev <subcommand>` now rejects unexpected trailing arguments (e.g. `sev start stop`) instead of silently ignoring them

### Added

- `sev --help` prints a generated usage block; `sev <subcommand> --help` prints subcommand-specific usage with that command's arguments and options
- Fix daemon `tmux` invocation under LaunchAgent — `Init.plist_contents/1` must emit `EnvironmentVariables` with a usable `PATH` (include `/opt/homebrew/bin`, `/usr/local/bin`), and/or `Severance.System.Real.tmux_cmd/1` should resolve tmux via `System.find_executable/1`. Daemon launched by `launchctl kickstart` inherits launchd's empty PATH, so `System.cmd("tmux", ...)` crashes with `:enoent` every publisher tick.
- Add [CLIMate](https://hexdocs.pm/cli_mate/readme.html) and update application to use it in order to simplify code

## [0.15.0] -- 2026-05-27

### Added

- Configurable publisher pipeline: declare `:publishers` in config to fan daemon status out to tmux or any user-supplied sink, each supervised with timeouts and a bounded error ring
- `sev init --with-tmux` opt-in flag that seeds the inline `tmux_countdown` publisher; default `sev init` now generates an empty `:publishers` map
- `sev init` prints a paste-ready tmux.conf block listing missing `#{@sev_*}` references (or "tmux.conf already wired." when complete)
- `sev status` surfaces per-publisher errors and missing tmux.conf wiring when unhealthy
- `sev status --<publisher-name>` and `--teardown` debug flags to invoke a publisher's function or teardown once locally
- `Severance.StatusPublisher.Tmux` builder with `set_var/2`, `clear_var/1`, and optional color/blink formatters for tmux-targeted publishers
- Publisher contract, `%Severance.Status{}` fields, tmux helpers, and lifecycle semantics documented in `docs/configuration.md`

### Changed

- Countdown no longer reads, overlays, or restores the user's tmux `status-right`; tmux side effects now live in the publisher pipeline
- `Countdown.status/0` returns a `%Severance.Status{}` struct threaded through the RPC + CLI render path

### Fixed

- `sev status` no longer crashes with `KeyError` when an older daemon returns a status map without `:version`
- `sev status --<publisher>` and `--teardown` run user functions in a monitored task with a 2s timeout, so a raising or hanging publisher no longer crashes or blocks the CLI
- `sev init --with-tmux` now resolves config before printing tmux instructions, so the paste block appears on first run
- Publisher task shutdown uses `brutal_kill` to avoid lingering tasks during supervisor restarts
- Publisher logs distinguish timeouts from crashes
- `sev status` renders "Shutdown:   not configured" instead of crashing when the daemon reports a nil `shutdown_time`

## [0.14.0] -- 2026-05-19

### Changed

- LaunchAgent now restarts the daemon on abnormal exits (`KeepAlive = { Crashed = true }`) so a mid-session crash no longer leaves you without a countdown until the next login
- Daemon logs moved from `/tmp/severance.{log,err}` to `~/Library/Logs/severance.{log,err}` so they survive macOS `/tmp` cleanup

## [0.13.0] -- 2026-04-17

### Added

- Make `sev <INVALID COMMAND>` error and not start severance

### Changed

- `sev <unknown command>` now prints an error and exits with a non-zero status instead of starting the daemon

## [0.12.0] -- 2026-04-17

### Added

- Address [this comment](https://github.com/KTSCode/severance/pull/11#discussion_r3041310901) from a closed PR
- `mix tag --patch/--minor/--major` now delegates version bumping and tagging to `mix_version`, with changelog finalization extracted into `mix changelog.finalize`
- Replace DIY `mix tag` with `mix_version` -- see `docs/plans/replace_tag_with_mix_version.md`

## [0.11.0] -- 2026-04-15

### Added

- Activity log tracking daemon sessions and overtime protocol usage (`sev log` to view)
- `log_file` configuration option for custom activity log location
- Investigate why the plist entry isn't starting `sev` on my machine
- add log file functionality that keeps track of how long you're sev has been running, and usage of overtime protocol

### Fixed
- `sev update` no longer overwrites the LaunchAgent plist when no plist existed before the update
- Updater tests no longer corrupt the real `~/Library/LaunchAgents` plist as a side effect

## [0.10.0] -- 2026-04-15

### Fixed
- `mix todo --done` CHANGELOG entries no longer land under a versioned `### Added` section
- `mix todo --done` prompt instructs the agent to rewrite raw TODO text as a user-facing changelog entry
- `mix todo --done` propagates `.todo-current` deletion errors instead of silently swallowing them

### Changed
- `mix todo --done` finds and squash-merges the existing PR instead of creating one
- `mix todo` start prompt tells the agent to push and create the PR, then wait for review

### Added
- `mix todo --done` opens the merged PR in the browser
- investigate why `mix todo --done` isn't getting called
- investigate why `mix todo --done` isn't getting called

## [0.9.0] -- 2026-04-14
 - Added `mix bump` to update deps

## [0.8.0] -- 2026-04-10
 - Removed `sev stop`

## [0.7.0] -- 2026-04-10

### Changed
- Shutdown uses osascript System Events instead of sudo, removing the sudoers requirement
- Shutdown retries use a fixed 60-second interval instead of exponential backoff with a 4-attempt cap

### Removed
- `sev init` no longer configures sudoers for passwordless shutdown

## [0.6.0] -- 2026-04-08

### Fixed
- Shutdown now uses `sudo /sbin/shutdown` instead of an osascript dialog that could go unnoticed
- `sev init` configures passwordless sudo for shutdown (one-time setup)
- Countdown timer survives macOS sleep by polling wall-clock time every 60s
- Late start (daemon started/restarted after shutdown time) now attempts shutdown on weekdays instead of only sending notifications

## [0.5.0] -- 2026-04-07

### Fixed
- Opt CI into Node.js 24 to silence GitHub Actions deprecation warning
- Start BEAM distribution in `start_daemon/1` so daemon registers with EPMD as `severance@hostname`

## [0.4.0] -- 2026-04-06

### Added
- `sev status` command showing daemon state, overtime mode, shutdown countdown, version, and update availability
- ETS-cached version check (24-hour TTL) for update availability in status output
- When I run `sev status` it says "not running" even though I'm getting the notifcations and tmux status line updates indicating that it is running.
- add a `mix bump` task that prints out a prompt will all the information necessary or instructions on how to get the information necessary to upgrade deps and configuration of the application. I'll call it with `mix bump | claude`

### Fixed
- `sev status` now shows the daemon's version instead of the CLI's after update-without-restart
- `sev status` checks for updates even when the daemon is not running

## [0.3.0] -- 2026-04-02

### Changed
- `sev` and `sev start` now spawn the daemon in the background and return immediately
- If the daemon is already running, `sev start` exits 0 with a status message
- Added `--daemon` flag for foreground mode (used by LaunchAgent and updater)
- Updater fallback restart uses `--daemon` instead of `start` to avoid preflight race
- Restrict `start` subcommand to start-specific options only

### Fixed
- Readiness polling uses retry loop (20 attempts at 500ms) for cold Burrito starts
- Stop distribution before spawning daemon to prevent node name conflicts
- Guard against self-connection when distribution is already running as daemon node
- Shell escaping in daemon spawn command to handle metacharacters in binary path

## [0.2.2] -- 2026-04-02
- Suppress noisy Erlang distribution errors during `sev update` daemon check

## [0.2.1] -- 2026-04-02
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
