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
# Both bounds must leave the whole gate comfortably under the hook's 900s timeout
# in .claude/settings.json. A hook that hits ITS timeout is canceled and renders no
# decision — the task completes ungated — while a command that hits an inner bound
# becomes an ordinary failure and blocks with a reason. The inner bound firing
# first is therefore load-bearing, not a courtesy. 600+300 plus the guards leaves
# real margin even when a concurrent second gate holds the SwiftPM build lock.
TEST_TIMEOUT=600
LINT_TIMEOUT=300

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$repo" || exit 0

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------- changed-file survey
# Nothing touched means nothing to verify. Research, planning, and review tasks
# complete without paying for a build.
changed() {
  # -uall: without it an untracked directory collapses to one "dir/" entry, so a
  # brand-new source folder never matches the \.swift$ keys below and the gate
  # skips lint and tests for it. Rename lines ("old -> new") must keep BOTH sides:
  # `git mv Foo.swift Foo.bak` deletes a Swift file from the build, and surveying
  # only the destination classifies that as a non-Swift change (--no-renames keeps
  # the committed case honest the same way). Paths with spaces or non-ASCII arrive
  # C-quoted ("like this"), so the trailing quote defeats the $-anchored keys too;
  # the last sed strips the quotes.
  { git --no-optional-locks status --porcelain -uall 2>/dev/null \
      | sed -E 's/^.{3}//' | sed -E 's/ -> /\n/'
    base="$(git rev-parse --verify -q origin/main 2>/dev/null || git rev-parse --verify -q main 2>/dev/null)"
    [[ -n "${base:-}" ]] && git diff --name-only --no-renames "$base...HEAD" 2>/dev/null
  } | sed -E 's/^"(.*)"$/\1/' | sed '/^$/d' | sort -u
}

files="$(changed)"
# An empty survey is NOT always "nothing to verify" (ROH-156). On main it means
# the work was committed and pushed before the task completed — origin/main
# advanced to HEAD, so the three-dot diff went empty at exactly the moment the
# code left the machine unverified. Fall back to the whole tracked tree there:
# completing a task on a clean, fully pushed main is rare in this repo's
# worktree flow, so the cost lands only on the risk-bearing shape. On any other
# branch an empty survey is the benign post-merge shape (tip already an ancestor
# of origin/main, nothing new to check) and skipping is correct — but say so,
# because a silent no-op is indistinguishable from inspected-and-passed, and
# only one of those is safe.
if [[ -z "$files" ]]; then
  branch="$(git symbolic-ref --short -q HEAD 2>/dev/null)"
  if [[ "$branch" == main || "$branch" == master ]]; then
    echo "aura-gate: change survey is empty but HEAD is on $branch — this work is already published, so inspecting the whole tracked tree instead." >&2
    # -z then NUL->newline: ls-files C-quotes unusual paths just like status
    # does, and the quoting would defeat the $-anchored keys below.
    files="$(git ls-files -z 2>/dev/null | tr '\0' '\n' | sed '/^$/d')"
  fi
  if [[ -z "$files" ]]; then
    echo "aura-gate: nothing to inspect (clean tree, no commits beyond origin/main); skipping lint, tests, and guards." >&2
    exit 0
  fi
fi

has() { grep -qE "$1" <<<"$files"; }

failures=()

run() {  # run <label> <dir> <cmd...>
  local label="$1" dir="$2"; shift 2
  local out rc
  out="$(cd "$dir" 2>/dev/null && "$@" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && return 0
  failures+=("--- ${label} (exit ${rc}) ---"$'\n'"$(tail -n "$MAX_LINES" <<<"$out")")
}

# The perl fallback matters: stock macOS ships neither timeout nor gtimeout, and
# an unbounded swift test is exactly what pushes the hook past ITS timeout, which
# completes the task ungated (see the bounds comment above).
tmo() { if have timeout; then timeout "$@"; elif have gtimeout; then gtimeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi; }

# ---------------------------------------------------------------------- Swift
# Fail open when the toolchain is missing rather than blocking on a machine that
# was never going to be able to run this.
if has '\.swift$'; then
  # --quiet, or the per-file progress stream is all that survives the tail.
  have swiftlint && run "swiftlint --strict" . tmo "$LINT_TIMEOUT" swiftlint lint --strict --quiet
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
# Keyed to the handoff machinery rather than to Swift: the wrapper, this gate,
# the suite, and the settings file that registers the hook are all pieces whose
# movement can stop the gate running, so any of them moving re-runs the suite
# (which also pins the registration in settings.json).
if has 'aura-task-gate\.sh$|test-task-gate\.sh$|\.claude/agent-gate\.sh$|\.claude/settings\.json$'; then
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
