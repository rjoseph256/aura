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
# Keyed to the handoff rather than to Swift: this one is about whether the wrapper
# still runs this script at all, so it matters exactly when that machinery moves.
if has 'aura-task-gate\.sh$|test-task-gate\.sh$'; then
  run "task-gate handoff guard" . bash scripts/test-task-gate.sh
fi

# --------------------------------------------------------------------- verdict
[[ ${#failures[@]} -eq 0 ]] && exit 0

{
  echo "Task blocked: Aura's quality gate failed on your changes."
  echo
  printf '%s\n\n' "${failures[@]}"
  echo "Fix these, re-run the failing command yourself to confirm it passes, then mark"
  echo "the task complete again. Do not disable or work around the gate."
  echo
  echo "Note this gate does not build the app or run pgTAP. CI still can fail after it passes."
} >&2
exit 2
