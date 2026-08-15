#!/usr/bin/env bash
#
# Aura's TaskCompleted quality gate.
#
# Exit 0 lets an agent mark a task complete. Any other exit blocks it, and stderr
# comes back to the agent as the reason.
#
# This path is a convention, not a coincidence: the global hook at
# ~/.claude/hooks/agent-gate.sh executes <repo>/.claude/agent-gate.sh in place of
# its own language detection when this file exists. So installing the global hook
# is enough to pick this up. Anyone without it gets here through the project hook
# declared in .claude/settings.json instead.
#
# Why a project gate at all, when the global one already handles Swift:
#
#   - The package needs `swift test --no-parallel`. The global gate runs a bare
#     `swift test`, which races the SwiftData suites against each other.
#   - The guard scripts CI runs have no generic equivalent.
#   - The package lives in AuraCore/, so a change confined to the app target
#     should still run the package suite.
#
# What this deliberately does NOT run, because a per-task gate has to stay fast:
# the xcodebuild app build (~13 min) and the pgTAP suite (needs a local Supabase
# stack). CI owns both. A green gate here is not a green CI.
#
# Escape hatch: AURA_SKIP_AGENT_GATE=1.

set -uo pipefail

[[ -n "${AURA_SKIP_AGENT_GATE:-}" ]] && exit 0

MAX_LINES=40
TEST_TIMEOUT=900   # the package suite is large; below this a slow machine reads as a failure
LOCK_WAIT=900      # seconds a second gate will wait for the first one's verdict

# ------------------------------------------------------------ re-entrancy guard
# This gate runs scripts/test-task-gate.sh, which runs a copy of the task-gate
# wrapper, which resolves a repo and can find its way back here. A nested run is a
# child process, so an exported marker is enough to stop it. Without this the chain
# is unbounded and each level costs a full lint-and-test pass (ROH-157 review).
[[ -n "${AURA_GATE_RUNNING:-}" ]] && exit 0
export AURA_GATE_RUNNING=1

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$repo" || exit 0

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------- changed-file survey
# Nothing touched means nothing to verify. Research, planning, and review tasks
# complete without paying for a build.
changed() {
  { git status --porcelain 2>/dev/null | sed -E 's/^.{3}//' | sed -E 's/^.* -> //'
    base="$(git rev-parse --verify -q origin/main || git rev-parse --verify -q main)" 2>/dev/null
    [[ -n "${base:-}" ]] && git diff --name-only "$base...HEAD" 2>/dev/null
  } | sed '/^$/d' | sort -u
}

files="$(changed)"
[[ -z "$files" ]] && exit 0

has() { grep -qE "$1" <<<"$files"; }

# --------------------------------------------------------------- sibling dedupe
# A machine with the global hook installed has TWO TaskCompleted hooks registered,
# and Claude Code runs matching hooks in parallel. Those are unrelated processes,
# so the marker above cannot see across them. Without dedupe they become two
# concurrent `swift test --no-parallel` runs contending for one SwiftPM build lock.
#
# The key is the tree, not the clock: HEAD plus the CONTENT of everything changed()
# reports. Two hooks firing for one event see a byte-identical tree and agree; two
# genuinely different tasks do not, so a stale verdict is never replayed. Content
# rather than paths, because the same dirty file edited twice has an identical
# `git status` line and a different right answer.
fingerprint() {
  { printf '%s\n' "$repo"
    git rev-parse HEAD 2>/dev/null
    while IFS= read -r f; do
      [[ -f "$f" ]] && shasum "$f" 2>/dev/null || printf 'absent %s\n' "$f"
    done <<<"$files"
  } | shasum | cut -d' ' -f1
}

cache="${TMPDIR:-/tmp}/aura-gate-$(fingerprint)"
lock="$cache.lock"

# Replays a recorded verdict and exits, or returns 1 if there is nothing fresh to
# replay. 15 minutes outlives the slowest legitimate gate and no more.
take_verdict() {
  [[ -f "$cache" ]] || return 1
  [[ -n "$(find "$cache" -mmin -15 2>/dev/null)" ]] || return 1
  local rc; rc="$(head -1 "$cache" 2>/dev/null)"
  [[ "$rc" =~ ^[0-9]+$ ]] || return 1
  [[ "$rc" -eq 0 ]] && exit 0
  tail -n +2 "$cache" >&2
  exit "$rc"
}

take_verdict || true

if ! mkdir "$lock" 2>/dev/null; then
  # Another gate owns this exact tree. Wait for its verdict rather than paying twice.
  waited=0
  while [[ -d "$lock" && $waited -lt $LOCK_WAIT ]]; do
    # The EXIT trap below clears the lock on any ordinary exit, so a lock that has
    # aged past the verdict TTL belongs to a process that was killed outright.
    # Waiting the full LOCK_WAIT on a corpse would stall every later task.
    if [[ -z "$(find "$lock" -maxdepth 0 -mmin -15 2>/dev/null)" ]]; then
      rmdir "$lock" 2>/dev/null; break
    fi
    sleep 1; waited=$((waited + 1))
  done
  take_verdict || true
  # It left without recording anything. Run it ourselves: a task must never pass on
  # the strength of a missing file.
  mkdir -p "$lock" 2>/dev/null
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT

failures=()

run() {  # run <label> <dir> <cmd...>
  local label="$1" dir="$2"; shift 2
  local out rc
  out="$(cd "$dir" 2>/dev/null && "$@" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && return 0
  failures+=("--- ${label} (exit ${rc}) ---"$'\n'"$(tail -n "$MAX_LINES" <<<"$out")")
}

tmo() { if have timeout; then timeout "$@"; elif have gtimeout; then gtimeout "$@"; else shift; "$@"; fi; }

# ---------------------------------------------------------------------- Swift
# Fail open when the toolchain is missing rather than blocking on a machine that
# was never going to be able to run this.
if has '\.swift$'; then
  # --quiet, or the per-file progress stream is all that survives the tail.
  have swiftlint && run "swiftlint --strict" . swiftlint lint --strict --quiet
  have swift && run "swift test --no-parallel" AuraCore tmo "$TEST_TIMEOUT" swift test --no-parallel
fi

# ---------------------------------------------------------------------- guards
# All three are cheap greps over the tree, so they run whenever anything they inspect
# could have moved. The terrain guard also owns the bundled style JSON.
if has '\.swift$'; then
  run "explore rename guard" . bash scripts/check-explore-rename.sh
fi
if has '\.swift$|AuraTerrainStyle\.json$'; then
  run "terrain style guard" . bash scripts/check-terrain-style.sh
fi
if has '\.swift$'; then
  run "single active-time definition" . bash scripts/check-single-active-definition.sh
fi
if has '\.swift$'; then
  run "monotonic instant guard" . bash scripts/check-monotonic-instants.sh
fi
# Keyed to the handoff itself rather than to Swift: these are about who runs this
# script and how often, so they matter exactly when that machinery moves (ROH-157).
# Both are seconds, and both unset AURA_GATE_RUNNING so their labs work even though
# this gate exported it.
if has 'aura-task-gate\.sh$|test-task-gate\.sh$'; then
  run "task-gate handoff guard" . bash scripts/test-task-gate.sh
fi
if has 'agent-gate\.sh$|test-agent-gate-dedupe\.sh$'; then
  run "agent-gate dedupe guard" . bash scripts/test-agent-gate-dedupe.sh
fi

# --------------------------------------------------------------------- verdict
# Recorded as well as reported, so a sibling gate waiting on the lock above gets
# this answer instead of recomputing it.
if [[ ${#failures[@]} -eq 0 ]]; then
  printf '0\n' >"$cache" 2>/dev/null
  exit 0
fi

verdict="$( {
  echo "Task blocked: Aura's quality gate failed on your changes."
  echo
  printf '%s\n\n' "${failures[@]}"
  echo "Fix these, re-run the failing command yourself to confirm it passes, then mark"
  echo "the task complete again. Do not disable or work around the gate."
  echo
  echo "Note this gate does not build the app or run pgTAP. CI still can fail after it passes."
} )"

{ printf '2\n'; printf '%s\n' "$verdict"; } >"$cache" 2>/dev/null
printf '%s\n' "$verdict" >&2
exit 2
