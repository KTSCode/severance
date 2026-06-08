# Architecture & Modifiability Pass

A documentation, architecture, and modifiability pass on the runtime
application. Two deliverables: a current-state architecture doc and a
behavior-preserving refactor that collapses the scattered countdown-phase
definitions into a single source of truth.

## Motivation

Phase knowledge is duplicated across four modules:

- `Countdown` — phase thresholds (`phase_for_remaining/1`) and tick
  intervals (`tick_interval_ms/1`, the `@*_interval_ms` attributes)
- `Notifier` — per-phase notification sound (`phase_sound/1`)
- `StatusPublisher.Tmux.Format` — per-phase color and blink
  (`color_for_phase/2`, `blink_for_phase/1`)
- `Status` — the `phase` type

Adding or re-ordering a phase means editing parallel clauses in four
files. The README roadmap lists "Configurable escalation phases" as
future work; that work has no single place to land today.

There is also no current-state architecture doc. `docs/specs/` holds
point-in-time design docs (some stale — they still reference the old
`STOP` phase name). The README documents usage, not internal structure.

## Deliverable 1: `Severance.Phase`

A new module that is the single source of truth for the escalating
countdown phases. Other modules delegate to it; no public signatures
change, so all existing tests stay green.

### Data

One ordered struct list. A phase is active while
`minutes_remaining > min_minutes`.

```elixir
@phases [
  %Phase{name: :waiting,    min_minutes: nil, interval_ms: nil,       sound: nil,     color_index: 0, blink?: false},
  %Phase{name: :gentle,     min_minutes: 15,  interval_ms: 5*60*1000, sound: "Tink",  color_index: 0, blink?: false},
  %Phase{name: :aggressive, min_minutes: 5,   interval_ms: 2*60*1000, sound: "Funk",  color_index: 1, blink?: true},
  %Phase{name: :final,      min_minutes: 0,   interval_ms: 60*1000,   sound: "Basso", color_index: 2, blink?: true},
  %Phase{name: :shutdown,   min_minutes: nil, interval_ms: nil,       sound: nil,     color_index: 2, blink?: false},
  %Phase{name: :done,       min_minutes: nil, interval_ms: nil,       sound: nil,     color_index: 2, blink?: false}
]
```

`color_index` is the position in a 3-element tmux palette
(`[waiting_or_gentle, aggressive, final_or_shutdown]`), preserving the
existing custom-palette behavior of `color_for_phase/2`.

### Public API

- `name/0` type — `:waiting | :gentle | :aggressive | :final | :shutdown | :done`
- `phase_for_remaining/1` — first escalation phase where
  `minutes > min_minutes`, else `:shutdown`
- `interval_ms/1` — tick cadence for a phase (nil for non-escalation phases)
- `sound/1` — notification sound for a phase
- `color/2` — `Enum.at(palette, color_index)`; defaults to `default_palette/0`
- `blink?/1` — boolean
- `default_palette/0` — `["colour51", "colour226", "colour196"]`

### Consumer changes (delegations only)

- `Countdown.phase_for_remaining/1` → `Phase.phase_for_remaining/1`
- `Countdown.tick_interval_ms/1` → `Phase.interval_ms/1`
- `Notifier.phase_sound(:overtime)` stays (mode-specific, not a phase);
  remaining clauses → `Phase.sound/1`
- `Format.color_for_phase/1,2` → `Phase.color/2`
- `Format.blink_for_phase/1` → derives from `Phase.blink?/1`
- `Status.@type phase` → `Severance.Phase.name()`

### Out of scope

These stay in `Countdown` — they are countdown timing, not per-phase
attributes:

- T-30 countdown-start window
- `@stale_threshold_minutes`
- `@wait_poll_ms`, `@shutdown_retry_ms`
- overtime-burst constants

Loading phases from config (the roadmap item) is also out of scope. This
pass only centralizes the static data so that work has one place to land.

## Deliverable 2: `docs/architecture.md`

A current-state, living architecture doc (distinct from the dated,
point-in-time `docs/specs/`). Linked from the README Development section.

Covers:

- Process model and supervision tree: `Application` → `Severance.Supervisor`
  → `Countdown` GenServer + `StatusPublisher.Supervisor` → per-publisher
  `Worker`s
- The two entry paths: CLI-command dispatch vs. daemon supervision tree
  (the `burrito?/0` branch in `Application.start/2`)
- Countdown state machine: `waiting → gentle → aggressive → final →
  shutdown | overtime → done`, midnight reset, weekend behavior
- Config resolution order (compiled < file < env < CLI flag)
- RPC seam: how `sev otp` / `sev status` reach the daemon
  (`severance@hostname`, EPMD, cookie)
- System adapter behaviour (`Severance.System`, real/test seam)
- Status publishers — pointer to `docs/configuration.md`
- `Severance.Phase` as the escalation source of truth

### Known rough edges

A short, honest section flagging coupling that this pass documents but
does not fix:

- `Application.resolve_config/2` writes resolved values into Application
  env as a side effect; `Countdown` and `Worker` read them piecemeal, so
  there is no single runtime source of truth for config
- RPC/distribution setup is duplicated between the daemon
  (`Application.ensure_distribution/0`) and the CLI's connect path
- The 880-line `CLI` module carries ~20 responsibilities (parse, RPC,
  daemon lifecycle, status formatting, publisher debug, usage text)

## Testing

- New `test/severance/phase_test.exs` — unit tests for each `Phase`
  function, mirroring the cases currently asserted via `Countdown`,
  `Notifier`, and `Format`
- Existing `countdown_test`, `notifier_test`, `format_test` stay
  unchanged and pass — they now exercise the delegations end-to-end,
  serving as the regression check that behavior is preserved
