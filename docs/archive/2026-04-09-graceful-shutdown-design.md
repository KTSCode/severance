# Graceful Shutdown: Remove sudo Requirement

## Problem

`sev init` configures a sudoers file for passwordless `sudo /sbin/shutdown`.
`System.cmd("sudo", ...)` cannot access the TTY for password input because
Elixir ports redirect stdio through pipes. This forces users to manually run
sudo commands after init fails.

The sudo approach was introduced in v0.6.0 after the original osascript
shutdown went unnoticed (the "System Events" dialog appeared behind other
windows). The fix overcorrected: a retry loop solves the reliability problem
without requiring elevated privileges.

## Design

### Shutdown mechanism

Revert `System.Real.shutdown_machine/0` from `sudo /sbin/shutdown -h now`
to `osascript -e 'tell app "System Events" to shut down'`.

This triggers a graceful macOS shutdown. Apps with unsaved changes present
save dialogs, which block the shutdown until dismissed.

### Retry strategy

Replace the current exponential-backoff retry (4 attempts, then gives up)
with a fixed-interval retry that runs indefinitely:

- **Interval:** 60 seconds
- **Max retries:** none (keeps firing until the machine shuts down or
  overtime is activated)
- **Rationale:** The save dialog blocks one attempt. The user sees it,
  dismisses it, and the next attempt succeeds. If the user walks away with
  unsaved work, the repeated attempts keep the dialog visible.

Changes to `Severance.Countdown`:

- Remove `@base_retry_ms`, `@max_retries`
- Remove `retry_delay_ms/1` (public, but only used internally and in tests)
- Add `@shutdown_retry_ms 60_000`
- Replace `{:retry_shutdown, attempt}` message with `:retry_shutdown`
  (no attempt counter, no stop condition)
- The stop-on-max-retries `handle_info` clause and its fallback notification
  become unnecessary

### Init cleanup

Remove from `Severance.Init`:

- `setup_sudoers/0` (private)
- `install_sudoers/0` (private)
- `copy_sudoers/1` (private)
- `sudoers_content/1` (public)
- `sudoers_configured?/0` (public)

Remove the `setup_sudoers()` call from `run/0`.

### Test changes

- `test/severance/system/real_test.exs` - expect osascript instead of sudo
- `test/severance/countdown_test.exs` - update retry tests for fixed-interval,
  no-limit behavior; remove `retry_delay_ms` tests
- `test/severance/init_test.exs` - remove sudoers tests

### Files changed

| File | Change |
|---|---|
| `lib/severance/system/real.ex` | Revert to osascript shutdown |
| `lib/severance/countdown.ex` | Fixed-interval retry, remove backoff |
| `lib/severance/init.ex` | Remove all sudoers code |
| `test/severance/system/real_test.exs` | Update shutdown expectations |
| `test/severance/countdown_test.exs` | Update retry tests |
| `test/severance/init_test.exs` | Remove sudoers tests |
