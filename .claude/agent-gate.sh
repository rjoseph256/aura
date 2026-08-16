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

# ------------------------------------------------------------- review baseline
# The baseline is the shared branch this repo publishes to: origin/HEAD first
# (whatever the remote actually calls its default), then the conventional names,
# then local main/master for repos with no remote at all.
base="" base_name=""
for cand in origin/HEAD origin/main origin/master main master; do
  if base="$(git rev-parse -q --verify "$cand^{commit}" 2>/dev/null)" && [[ -n "$base" ]]; then
    base_name="$cand"; break
  fi
  base=""
done
head_sha="$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)"

# ------------------------------------------------------------- changed-file survey
# Nothing touched means nothing to verify — except at the published tip, where
# that inference inverts; see the fallback below. Research, planning, and review
# tasks elsewhere complete without paying for a build.
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
    [[ -n "$base" ]] && git diff --name-only --no-renames "$base...HEAD" 2>/dev/null
  } | sed -E 's/^"(.*)"$/\1/' | sed '/^$/d' | sort -u
}

files="$(changed)"

# ------------------------------------------- published work is never skipped (ROH-156)
# The survey keys off "what differs from the baseline", and PUSHING MOVES THE
# BASELINE: the moment work reaches the shared branch, the three-dot diff goes
# empty — at exactly the moment the code left the machine unverified. So when
# HEAD *is* the published tip, the survey widens to the whole tracked tree.
#
# The trigger is a SHA comparison, deliberately not a branch name and not
# survey emptiness. A branch name discriminates nothing: a feature branch
# pushed straight to origin/main is byte-identical in git to one that got there
# by a reviewed merge, and a detached HEAD at the tip is the same state with no
# name at all. And emptiness self-disarms: the gate's own `swift test` dirties
# AuraCore/Package.resolved (ROH-182), and that one stray non-Swift line would
# otherwise suppress the fallback forever on the primary checkout.
#
# Costs, decided deliberately: any task completed at the published tip — the
# post-merge fast-forwarded main checkout included — pays the full suite, and a
# red main blocks completions there that changed nothing (loudly, which is the
# point: the alternative was certifying a broken published tree by silence).
# The worktree/branch flow keeps most task completions off the published tip.
# Known residual, accepted: work pushed to the shared branch that someone
# else's merge then buries (HEAD strictly behind by completion time) is not
# re-inspected here; CI still covers it.
#
# A repo with an origin but NO resolvable baseline (a single-branch clone of a
# feature branch) cannot certify "nothing new to verify", so it fails safe into
# the same whole-tree survey.
fallback=""
if [[ -n "$head_sha" && "$base_name" == origin/* && "$head_sha" == "$base" ]]; then
  fallback="HEAD is the published tip of $base_name"
elif [[ -z "$base" ]] && git config --get remote.origin.url >/dev/null 2>&1; then
  fallback="no review baseline resolves (tried origin/HEAD, origin/main, origin/master, main, master) although an origin remote exists"
fi
if [[ -n "$fallback" ]]; then
  echo "aura-gate: $fallback — surveying the whole tracked tree instead of only the change survey." >&2
  # ls-files -z then NUL->newline: ls-files C-quotes unusual paths just like
  # status does, and the quoting would defeat the $-anchored keys below.
  files="$({ printf '%s\n' "$files"; git ls-files -z 2>/dev/null | tr '\0' '\n'; } | sed '/^$/d' | sort -u)"
fi
if [[ -z "$files" ]]; then
  # A silent no-op is indistinguishable from inspected-and-passed, and only one
  # of those is safe — so the skip says what it skipped and why. The wrapper
  # forwards this on success; it surfaces in the hook transcript, not to the
  # agent (only exit 2 reaches the agent, and blocking on a benign skip would
  # be worse than the message being quiet).
  if [[ -n "$base" ]]; then
    echo "aura-gate: nothing to inspect — clean tree and HEAD already contained in $base_name; skipping lint, tests, and guards." >&2
  else
    echo "aura-gate: nothing to inspect — clean tree, no commits, no baseline; skipping lint, tests, and guards." >&2
  fi
  exit 0
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
  # Bounded like the other children: the whole-tree fallback above matches this
  # key on every firing, and an unbounded child on that path is exactly the
  # hook-timeout ungated-pass hazard the bounds comment describes.
  run "task-gate handoff guard" . tmo 120 bash scripts/test-task-gate.sh
fi

# --------------------------------------------------------------------- verdict
[[ ${#failures[@]} -eq 0 ]] && exit 0

{
  if [[ -n "$fallback" ]]; then
    echo "Task blocked: Aura's quality gate failed on the whole-tree survey ($fallback)."
    echo "The failures below may predate your task — but the published tree is what's broken."
  else
    echo "Task blocked: Aura's quality gate failed on your changes."
  fi
  echo
  printf '%s\n\n' "${failures[@]}"
  echo "Fix these, re-run the failing command yourself to confirm it passes, then mark"
  echo "the task complete again. Do not disable or work around the gate."
  echo
  echo "Note this gate does not build the app or run pgTAP. CI still can fail after it passes."
} >&2
exit 2
