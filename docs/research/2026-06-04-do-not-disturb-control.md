# Do Not Disturb Control — 2026-06-04

How Severance could turn macOS Do Not Disturb / Focus on (and off) on the
host machine, plus how to wire a user-supplied script and a calendar guard
around it.

This is a research note only. No implementation decision is made here; it
catalogs the realistic approaches with tradeoffs, grounds them in the
current code, and lists the open questions a follow-up spec must answer.

## Why this matters

The user wants two things:

- A way for Severance to enable Do Not Disturb on the host so the wind-down
  window is actually quiet, with the ability to **run a user script or
  config function at the DND on/off boundaries**.
- **Calendar access** so Severance can guarantee it never silences (or
  shuts down through) a real meeting.

Both are "how do we wire it" asks. The hard part is that macOS has no
public, stable API for setting Focus/DND, and the unofficial paths keep
breaking across OS releases — most recently on the version this machine is
already running.

## The moving target (read this first)

"Do Not Disturb" is now one of several **Focus** modes (macOS 12 Monterey
renamed and restructured the feature). The programmatic surface has changed
in every major release since:

- The legacy `defaults -currentHost write … com.apple.notificationcenterui
  doNotDisturb` trick **stopped working in Monterey** and is dead on
  anything modern ([iBoysoft][iboysoft], [Kap issue][kap]).
- The current unofficial store, `~/Library/DoNotDisturb/DB/Assertions.json`,
  was the go-to from Monterey through Sequoia — but it **changed shape on
  macOS 26 (Tahoe)** and existing scripts that poke it broke
  ([brunerd][brunerd], [macos-focus crate][macos-focus]). This box is on
  Tahoe, so any approach that depends on that file is already suspect.

**Constraint:** treat every approach below as version-fragile except the
Shortcuts one. Whatever we pick needs a "this stopped working" failure mode
that is loud, not silent — a daemon that *thinks* it enabled DND but didn't
is worse than no feature.

## Current behavior

Severance has no DND/Focus concept today. The relevant seams it would plug
into:

- `Severance.System` behaviour (`lib/severance/system.ex:10-12`) defines the
  OS interaction callbacks: `notify/3`, `shutdown_machine/0`, `tmux_cmd/1`.
  A DND toggle is a natural fourth callback here.
- `Severance.System.Real` (`lib/severance/system/real.ex`) implements them by
  shelling out to `osascript`. A real DND impl would shell out the same way.
- The publisher contract (`lib/severance/status_publisher/worker.ex:1-60`)
  is the existing pattern for **user-supplied functions invoked on a
  schedule with `:setup`/`:teardown` lifecycle hooks** — directly reusable
  shape for "run my script at the DND boundaries."

## Approaches to turning DND/Focus on

### A. Shortcuts CLI (`shortcuts run`) — recommended

macOS Monterey+ ships a `shortcuts` CLI. Create a Shortcut once containing a
**Set Focus** action ("Do Not Disturb → On, until turned off"), then:

```bash
shortcuts run "Severance DND On"
shortcuts run "Severance DND Off"
```

([heyfocus][heyfocus], [Apple Support][apple-focus].)

- **Pro:** the only approach built on a *documented, sanctioned* API. The
  Set Focus action is a first-class Shortcuts action Apple maintains across
  releases — the most likely to survive an OS upgrade.
- **Pro:** drops straight into `System.Real` as `System.cmd("shortcuts",
  ["run", name])`, mirroring the existing `osascript` calls.
- **Pro:** the same Shortcut can compose other actions (e.g. a calendar
  check, see below) natively.
- **Con:** requires a per-machine setup step — the user (or `sev init`) must
  create the named Shortcut. We can't fully self-install it; Shortcuts has
  no clean CLI import that survives signing. `sev init` would have to print
  instructions or ship a `.shortcut` file to double-click.
- **Con:** first invocation from a non-interactive LaunchAgent may trip an
  automation-permission prompt; a background daemon can't always surface it.
  Needs testing under `launchctl`, like the PATH issue already hit for
  `tmux_cmd/1`.
- **Con:** `shortcuts run` is fire-and-forget — verifying the Focus actually
  changed means reading state back separately (see "Reading state").

### B. Poke the DoNotDisturb DB + nudge `donotdisturbd`

Write an `AssertionRecord` into `~/Library/DoNotDisturb/DB/Assertions.json`
(and `ModeConfigurations.json`), post the legacy Darwin
`notify_post`/`DistributedNotificationCenter` names, then
`launchctl kickstart -k …/donotdisturbd` and restart `ControlCenter` so the
menu-bar badge refreshes ([brunerd][brunerd], [JXA gist][jxa-gist]).

- **Pro:** no extra setup artifact; pure file + signal manipulation as the
  logged-in user. `~/Library/DoNotDisturb/DB/` is user-owned and not
  SIP-protected.
- **Con (blocking):** the JSON schema **changed on macOS 26 (Tahoe)** and
  the data isn't where it used to be — known-broken on this machine's OS
  ([macos-focus crate][macos-focus]). High maintenance, reverse-engineered,
  undocumented.
- **Con:** belt-and-suspenders signaling (multiple notify names + daemon
  kick + ControlCenter restart) is brittle and racy. Easy to leave the UI
  and the actual state disagreeing.
- **Verdict:** powerful but a maintenance trap. Only viable if A can't meet
  a requirement, and only with a per-OS-version compatibility shim.

### C. AppleScript UI scripting of Control Center

`osascript` that opens Control Center and clicks Focus → Do Not Disturb.

- **Con:** requires Accessibility permission, breaks on every UI/layout/
  localization change, and is slow and visible. Same class of fragility as
  the interrupted-shutdown UI-scripting dead ends. Avoid.

### D. Legacy `defaults write notificationcenterui` — dead

Listed only to rule it out: this is the pre-Monterey method and does not
work on modern macOS ([iBoysoft][iboysoft], [Kap issue][kap]). Do not use.

### E. Third-party CLIs / libraries

- **`joeyhoer/dnd`** ([repo][dnd-cli]) — a CLI that drives DND via AppleScript
  System Events; needs Accessibility permission. Same fragility as C, just
  packaged.
- **`sindresorhus/do-not-disturb`** ([repo][sindre-dnd]) — Node/Swift wrapper
  exposing `enable`/`disable`/`toggle`/`isEnabled`. The author states there
  is **no public macOS API** and it **does not work inside a sandboxed app**.
- **`macos-focus`** ([crate][macos-focus]) — Rust crate that manipulates the
  DoNotDisturb DB (approach B); its own notes flag the Tahoe breakage.

All three are approach B or C under a wrapper, and adding a non-Elixir
runtime dependency cuts against the project's "OTP stdlib only" leaning
(cf. the dependency-free updater). Useful as reference implementations, not
as a dependency.

## Reading state (for verification and toggling)

Any "enable DND" needs a "did it work / is it already on" read-back. Options
mirror the write paths:

- Detect via the DB: `grep -q storeAssertionRecords
  ~/Library/DoNotDisturb/DB/Assertions.json` was the Monterey→Sequoia tell
  ([brunerd][brunerd]) — but subject to the same Tahoe schema break.
- A Shortcut with a **Get Current Focus** action, read back via
  `shortcuts run` output. Sanctioned, version-stable, pairs with approach A.

## Wiring the user script / config function

The user wants "a script or a function in the config that is run at the do
not disturb intervals." Severance already has the exact pattern for
user-supplied functions with lifecycle hooks — the publisher contract
(`lib/severance/status_publisher/worker.ex`), where a config entry is a map
of `%{fn: …, setup: …, teardown: …, interval_ms: …}` invoked inside a
timeout-guarded `Task`. Three integration shapes, in rough order of
cleanliness:

1. **DND transition hooks in config (recommended shape).** Add a config key
   such as:

   ```elixir
   dnd: %{
     enable: fn -> System.cmd("shortcuts", ["run", "Severance DND On"]) end,
     disable: fn -> System.cmd("shortcuts", ["run", "Severance DND Off"]) end
   }
   ```

   Severance calls `enable` when it crosses *into* a DND window and `disable`
   when it crosses out. Semantics match the ask exactly ("run at the
   intervals" = at the on/off boundaries, not every tick). Reuse the
   publisher's `Task`-with-timeout + bounded-error-ring machinery so a
   hanging user fn can't wedge the daemon.

2. **A new `System` behaviour callback.** Add `@callback
   set_do_not_disturb(boolean) :: :ok` to `Severance.System`, with
   `System.Real` shelling `shortcuts run` and `System.Test` recording calls.
   The config hook in (1) defaults to this when the user supplies no fn. This
   keeps the OS-specific bit testable like `notify/3` and `shutdown_machine/0`
   already are.

3. **Reuse publishers as-is.** A publisher whose `fn` toggles DND. Cheapest
   (zero new code) but wrong semantics: publishers fire every `interval_ms`,
   not on transitions, and are conceptually status-bar sinks. Mention only
   as the do-nothing option.

**Open design question (spec, not research):** *when* is a "DND interval"?
Candidates: the escalation countdown window, the post-shutdown-time period,
overtime/grace mode, or an independent user-configured schedule. The README
escalation phases (Gentle/Aggressive/Final) are the obvious anchor, but this
is a behavior decision, not a technical one.

## Calendar guard (don't silence a meeting)

The user wants calendar access so Severance won't enable DND (or shut down)
through a meeting. macOS calendar reads, cheapest first:

- **Shortcuts "Get Upcoming Events" action**, composed into the *same*
  Shortcut that sets Focus (approach A). The guard runs natively inside the
  sanctioned tool — no new dependency, and the TCC calendar prompt is
  Shortcuts' problem, not the daemon's. Best fit if we go with A.
- **`icalBuddy`** (`brew install ical-buddy`): `icalBuddy eventsNow` /
  `eventsToday` to list current/upcoming events ([commandmasters][icalbuddy]).
  Simple text output, easy to parse in Elixir. Adds a Homebrew dependency.
- **`ical`** (Go, binds EventKit directly, [BRO3886/ical][ical-go]) — fastest
  for big calendars, reads every account Calendar.app syncs. Another non-OTP
  binary dependency.

**Con / blocking gotcha for all of them:** reading the calendar needs
**EventKit / TCC calendar permission**, and Severance runs as a background
LaunchAgent. Background daemons cannot reliably present the TCC consent
prompt — the permission usually has to be granted by an interactive run
first, or pre-authorized. This is the same class of problem as the Shortcuts
automation prompt in approach A and must be validated under `launchctl`
before relying on it. The Shortcuts-native path sidesteps the daemon holding
calendar permission directly, which is a point in its favor.

The guard logic itself is trivial once a read works: before enabling DND or
shutting down, check for an event overlapping now (or within N minutes) and
skip/defer if one exists.

## Recommendation (for the follow-up spec, not decided here)

- **Enable DND via approach A (Shortcuts CLI).** It's the only path on a
  documented API and the only one not already broken on this machine's macOS
  26. Accept the one-time per-machine Shortcut setup as the cost.
- **Expose DND toggling as a `System` callback (shape 2) with an optional
  config-fn override (shape 1)** so the OS bit stays testable and the user
  can drop in their own script.
- **Do the calendar guard inside the same Shortcut (Get Upcoming Events)**
  rather than giving the daemon its own EventKit permission.
- Keep approach B documented as the fallback *only* if A proves it can't read
  or set a required state, and only behind a per-OS-version shim with a loud
  failure mode.

## Open questions before implementing

- **When does DND turn on/off?** (Anchor to escalation phases, post-shutdown,
  overtime, or an independent schedule?) Decides the whole feature shape.
- Can a `launchctl`-spawned LaunchAgent run `shortcuts run` without an
  interactive automation prompt? Test before committing to A.
- Same question for calendar TCC: can the daemon (or its Shortcut) read
  events headless, or does it need a one-time interactive grant during
  `sev init`?
- How does `sev init` deliver the named Shortcut(s) — printed instructions, a
  shipped `.shortcut` file, or generated on the fly? (No clean CLI import
  exists.)
- Verify the read-back path: does **Get Current Focus** via `shortcuts`
  return parseable state on macOS 26, given the DB approach broke there?
- What's the meeting buffer (skip DND/shutdown if an event is within N
  minutes), and does an all-day event count?

## Security & governance note

This is a personal-machine tool, so no shared-credential or external-data
concern — but two new permission surfaces appear:

- **Calendar (TCC):** granting Severance (or its Shortcut) calendar read
  access exposes event titles/times to the daemon and any config fn it runs.
  Keep it read-only, and if the config-fn override (shape 1) is used, the
  same warning as publishers applies — `config.exs` is evaluated as live
  Elixir (`lib/severance/config.ex:6-9`), so a DND/calendar fn runs with full
  process privileges. Review any such fn before starting the daemon.
- **Automation (Apple Events / Accessibility):** approaches A, C, and E
  require automation or Accessibility grants. Prefer A's narrow,
  Shortcuts-mediated grant over C/E's blanket Accessibility access.

Neither leaves the machine, but both are consent surfaces worth an explicit
note in the eventual `sev init` flow so the user knows what they're granting
and why.

[iboysoft]: https://iboysoft.com/howto/mac-notifications-not-showing.html
[kap]: https://github.com/wulkano/kap/issues/433
[brunerd]: https://www.brunerd.com/blog/2022/03/07/respecting-focus-and-meeting-status-in-your-mac-scripts-aka-dont-be-a-jerk/
[macos-focus]: https://crates.io/crates/macos-focus
[heyfocus]: https://heyfocus.com/blog/how-to-turn-on-mac-focus-mode-from-the-terminal/
[apple-focus]: https://support.apple.com/guide/mac-help/turn-a-focus-on-or-off-mchl999b7c1a/mac
[jxa-gist]: https://gist.github.com/drewkerr/0f2b61ce34e2b9e3ce0ec6a92ab05c18
[dnd-cli]: https://github.com/joeyhoer/dnd
[sindre-dnd]: https://github.com/sindresorhus/do-not-disturb
[icalbuddy]: https://commandmasters.com/commands/icalbuddy-osx/
[ical-go]: https://github.com/BRO3886/ical
