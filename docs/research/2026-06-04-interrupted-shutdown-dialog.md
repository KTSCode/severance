# Interrupted Shutdown Dialog — 2026-06-04

How to get past the macOS "*<App>* interrupted shutdown" dialog so a
Severance hard shutdown actually completes.

This is a research note only. No implementation decision is made here; it
catalogs the realistic approaches with tradeoffs so we can pick one in a
follow-up spec.

## Why this matters

Severance's whole premise is that the default path is "your computer turns
off." When an app vetoes the shutdown, that premise breaks: the machine
stays up, the user keeps working, and the retry loop just re-triggers the
same dialog every minute. The boundary becomes a suggestion again.

## Current behavior

`Severance.System.Real.shutdown_machine/0`
(`lib/severance/system/real.ex:51-62`) runs:

```elixir
osascript -e 'tell application "System Events" to shut down'
```

This is a *graceful* shutdown. macOS sends every running app a quit Apple
event and lets each one veto. `Severance.Countdown` retries on a 60s timer
(`@shutdown_retry_ms`, `lib/severance/countdown.ex:200-204` and
`277-289`), but retrying does not help: the same app vetoes again and the
same dialog reappears.

The current docstring already acknowledges this — it says apps "present
save dialogs, which block the shutdown until dismissed."

## Root cause

When macOS shuts down it sends each app `applicationShouldTerminate:`.
An app returns `NSTerminateCancel` (or shows a modal "unsaved changes"
sheet) and the shutdown is aborted. macOS surfaces this as
"*<App>* interrupted shutdown" / "Your Mac hasn't shut down because
'*<App>*' failed to quit." This is intended OS behavior, not a bug —
Apple's documented `applicationShouldTerminate(_:)` delegate is the
sanctioned way for an app to veto ([Tauri issue][tauri], [Apple
Community][apple-interrupted]).

**The hard constraint:** a non-root process cannot force a shutdown past
this veto. `/sbin/shutdown` is root-only; a normal user gets "permission
denied" ([Apple Community][apple-terminal], [osxdaily][osxdaily]).
Severance runs as a per-user LaunchAgent (`com.severance.daemon`) with no
elevated privileges. So every viable approach is one of: (a) acquire
privilege, or (b) remove the vetoing apps before asking to shut down.

## Approaches

### A. Passwordless sudo + `/sbin/shutdown -h now`

Install a `sudoers` drop-in so the daemon can run the privileged shutdown
non-interactively:

```text
# /etc/sudoers.d/severance  (mode 0440, root:wheel)
<user> ALL=(root) NOPASSWD: /sbin/shutdown -h now
```

`shutdown_machine/0` then runs `sudo /sbin/shutdown -h now`.

- **Pro:** truly forces shutdown. The kernel-level path sends SIGTERM then
  SIGKILL; apps do not get to veto. The dialog never appears. Most robust.
- **Con:** privilege escalation. Requires writing a root-owned `sudoers`
  file, almost certainly during `sev init` with an interactive `sudo`
  prompt (the daemon cannot self-install it). A malformed `sudoers` file
  is a real foot-gun. Severance now manages a privileged config file.
- **Con:** `-h now` gives apps zero save chance — same destructive outcome
  as approach B, just enforced by the OS instead of by us.
- **Note (verify):** narrow the command match exactly; a loose `sudoers`
  entry (e.g. allowing all of `/sbin/shutdown`) widens the blast radius.

### B. Force-quit GUI apps, then graceful shutdown

No root. Before issuing the System Events shutdown, terminate the visible
GUI apps so nothing is left to veto:

```text
# enumerate visible apps, then SIGTERM -> SIGKILL stragglers, then:
osascript -e 'tell application "System Events" to shut down'
```

Enumerate via System Events
(`name of (every process whose background only is false)`) or
`kill`/`pkill` on the app processes.

- **Pro:** no privilege escalation; stays within the current LaunchAgent
  permission model.
- **Pro:** with the apps gone there is nothing to present the dialog, so
  the subsequent System Events shutdown is reliable.
- **Con:** destroys unsaved work with no save prompt. (Arguably on-brand
  for a hard-shutdown enforcement tool, but it is a behavior change worth
  an explicit decision.)
- **Con:** races. An app launched between the kill sweep and the shutdown
  call can still veto. Mitigate by killing inside the same step that calls
  shutdown, or by looping kill→shutdown.
- **Con:** killing Terminal/iTerm with running processes is exactly the
  kind of veto we are bypassing; fine for the daemon (it does not run
  inside those), but it means in-flight shell work dies silently.

### C. loginwindow Apple events

`osascript -e 'tell app "loginwindow" to «event aevtshut»'` triggers the
same shutdown the Apple menu does.

- The force-*logout* variant `«event aevtrlgo»` "will quickly force a
  logout, in most cases ignoring open documents" ([DssW][dssw]).
- **But:** that is logout, not shutdown, and even it is documented as
  best-effort ("in most cases") — apps can still hang it. There is no
  documented shutdown Apple event that kills a hung/vetoing app without
  privilege.
- **Inference (unverified):** the loginwindow shutdown event is subject to
  the same `applicationShouldTerminate:` veto as the current System Events
  call, so it is not a reliable bypass on its own. Treat as a dead end
  unless testing proves otherwise.

### D. `pmset schedule shutdown`

`sudo pmset schedule shutdown "MM/dd/yy HH:mm:ss"` registers a power event
with `powerd`.

- **Con:** still root-only, so it carries the same privilege-escalation
  cost as approach A with none of approach A's "now" determinism.
- **Con (verify):** scheduled `pmset` shutdowns are believed to still run
  the normal app-quit path and can be interrupted by a vetoing app.
  Unverified — would need testing before relying on it.
- Not obviously better than A. Listed for completeness.

### Reference: commercial privileged helpers

Tools like DssW Power Manager advertise logout/shutdown that "will not be
stopped by application dialog boxes" ([DssW][dssw]). They achieve this with
a privileged launchd helper — i.e. the same root requirement as approach
A, packaged. Confirms the constraint: bypassing the veto needs privilege.

## Recommendation (for the follow-up spec, not decided here)

Two honest finalists:

- **A (sudo shutdown)** if we accept a one-time privileged `sev init`
  step. Cleanest runtime behavior, OS-enforced.
- **B (force-quit then shutdown)** if we refuse to manage a `sudoers` file.
  Works today with no privilege change, at the cost of a more violent,
  race-prone kill sweep we maintain ourselves.

Both destroy unsaved work. Approach C is likely a dead end; D is A with
extra uncertainty. Pick A vs B based on appetite for privilege escalation
vs. owning an app-killing routine.

## Open questions before implementing

- Will Severance own a root-owned `sudoers` file? (Decides A vs B.)
- Is destroying unsaved work acceptable, or should there be one save pass
  with a bounded timeout before the forceful step?
- For B: enumerate-and-kill via System Events vs `pkill` — which is more
  reliable under the daemon's empty `launchctl` PATH? (Compare the PATH
  fix already applied to `tmux_cmd/1`.)
- Verify C and D empirically before discarding, since both claims above
  are inferences.

## Security & governance note

Approach A introduces a root-owned `sudoers` entry and a privileged
shutdown the daemon can invoke without a password — a meaningful local
privilege-escalation surface. Keep the command match as narrow as possible
(exact path + exact args), set the file `0440 root:wheel`, and validate
with `visudo -c` before install. This is a personal-machine tool, so no
shared-credential or external-data concern, but the privileged file is the
highest-risk artifact in either approach and deserves review before
shipping.

[tauri]: https://github.com/tauri-apps/tauri/issues/12978
[apple-interrupted]: https://discussions.apple.com/thread/251282633
[apple-terminal]: https://discussions.apple.com/thread/251479837
[osxdaily]: https://osxdaily.com/2017/08/13/shutdown-mac-command-line/
[dssw]: https://www.dssw.co.uk/blog/2010-10-27-how-to-log-out-users-with-applescript/
