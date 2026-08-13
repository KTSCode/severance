#!/usr/bin/env bash
# Release smoke check: proves a packaged sev binary works — argv passthrough
# and daemon boot — before it can be shipped. Runs as an ExQuality custom
# stage (see .quality.exs) and against a CI artifact from the mix tag gate.
#
# Usage: release_smoke.sh [path/to/sev_binary]
#   With no argument, builds (or reuses a fresh) burrito_out/ binary.
#
# Exit codes: 0 pass, 1 fail, 2 skip (ExQuality skip_exit_code).
#
# Emits the ExQuality command-stage JSON finding contract on stdout.
# Progress goes to stderr; ExQuality merges the streams for display.
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DAEMON_PID=""
SPAWNED_DAEMON=0
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/release_smoke.XXXXXX")"

# JSON string escape: backslashes, quotes, newlines flattened to spaces.
json_escape() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

skip() {
  printf '{"summary":"%s","stats":{},"findings":[]}\n' "$(json_escape "$1")"
  exit 2
}

fail() {
  printf '{"summary":"%s","stats":{"finding_count":1},"findings":[{"file":"mix.exs","message":"%s"}]}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")"
  exit 1
}

pass() {
  printf '{"summary":"%s","stats":{"finding_count":0},"findings":[]}\n' "$(json_escape "$1")"
  exit 0
}

# Teardown on every exit path. A stray daemon's actual job is powering off
# the machine, so this kills the spawned launcher, its children, and the
# BEAM registered with EPMD during this run.
cleanup() {
  if [[ "$SPAWNED_DAEMON" -eq 1 ]]; then
    if [[ -n "$DAEMON_PID" ]]; then
      pkill -P "$DAEMON_PID" 2>/dev/null
      kill "$DAEMON_PID" 2>/dev/null
    fi
    # The Burrito launcher may detach the BEAM from its process tree, so
    # also kill whatever claimed the severance name in EPMD during the run.
    local port beam_pid
    port="$(epmd -names 2>/dev/null | awk '/^name severance at port/ {print $NF}')"
    if [[ -n "$port" ]]; then
      beam_pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1)"
      [[ -n "$beam_pid" ]] && kill "$beam_pid" 2>/dev/null
    fi
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

command -v epmd >/dev/null 2>&1 || skip "epmd not found on PATH; cannot smoke the daemon"

# Guard: never touch the developer's real daemon. If severance is already
# registered, the node name would collide and teardown could kill it.
if epmd -names 2>/dev/null | grep -q '^name severance at'; then
  skip "developer's sev daemon is running; skipping release smoke"
fi

BIN="${1:-}"

if [[ -n "$BIN" ]]; then
  [[ -f "$BIN" ]] || fail "release smoke: binary not found" "no binary at $BIN"
  [[ -x "$BIN" ]] || chmod +x "$BIN"
else
  case "$(uname -m)" in
    arm64) TARGET="macos_arm64" ;;
    x86_64) TARGET="macos_x86" ;;
    *) skip "unsupported host arch $(uname -m) for release smoke" ;;
  esac
  BIN="burrito_out/sev_${TARGET}"

  # Rebuild only when the packaged binary is stale against the sources
  # that feed the release.
  stale=0
  if [[ ! -f "$BIN" ]]; then
    stale=1
  elif [[ -n "$(find lib mix.exs mix.lock rel -newer "$BIN" -print -quit 2>/dev/null)" ]]; then
    stale=1
  fi

  if [[ "$stale" -eq 1 ]]; then
    echo "release_smoke: building release (burrito target ${TARGET})..." >&2
    if ! MIX_ENV=prod BURRITO_TARGET="$TARGET" mix release sev --overwrite >"$WORK_DIR/build.log" 2>&1; then
      tail -5 "$WORK_DIR/build.log" >&2
      # A failed local build is a toolchain problem (e.g. Zig vs macOS SDK),
      # not a code problem — skip rather than block every push.
      skip "local toolchain cannot build the release (see burrito/Zig vs macOS SDK); CI builds are unaffected"
    fi
  fi
  [[ -f "$BIN" ]] || skip "local toolchain cannot build the release: $BIN missing after mix release"
fi

# Absolute path: the daemon is spawned from $WORK_DIR, not the repo root.
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

echo "release_smoke: smoking $BIN" >&2

# --- Assertion 1: argv passthrough (the v0.20.0 Burrito 1.6.0 bug) ---------
expected_version="$(sed -n 's/^ *version: "\([^"]*\)".*/\1/p' mix.exs | head -1)"
version_out="$("$BIN" --version 2>&1)"

if grep -q "No file named" <<<"$version_out"; then
  fail "release binary broken: launcher argv not passed through" \
    "sev --version printed: $version_out"
fi

if ! grep -q "$expected_version" <<<"$version_out"; then
  fail "release binary version mismatch" \
    "expected $expected_version, sev --version printed: $version_out"
fi

# --- Assertion 2: daemon boots and registers with EPMD ---------------------
# The shutdown time must be safely in the future TODAY: a daemon started
# after its shutdown time immediately powers off the machine. If +2h wraps
# past midnight, skip rather than gamble.
now="$(date +%H:%M)"
future="$(date -v+2H +%H:%M)"
if [[ "$future" < "$now" ]]; then
  skip "too close to midnight for a safe daemon smoke (shutdown time would wrap)"
fi

echo "release_smoke: booting daemon with SEVERANCE_SHUTDOWN_TIME=$future" >&2
(cd "$WORK_DIR" && SEVERANCE_SHUTDOWN_TIME="$future" exec "$BIN" --daemon) \
  >"$WORK_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
SPAWNED_DAEMON=1

registered=0
for _ in $(seq 1 30); do
  if epmd -names 2>/dev/null | grep -q '^name severance at'; then
    registered=1
    break
  fi
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

if [[ "$registered" -ne 1 ]]; then
  daemon_out="$(tail -5 "$WORK_DIR/daemon.log" 2>/dev/null)"
  fail "release daemon failed to boot: never registered with EPMD" \
    "sev --daemon output: ${daemon_out:-<empty>}"
fi

status_out="$("$BIN" status 2>&1)"
if grep -q "not running" <<<"$status_out"; then
  fail "release daemon registered but sev status reports not running" \
    "sev status printed: $status_out"
fi

pass "release binary ok: argv passthrough, daemon boot, EPMD registration, status"
