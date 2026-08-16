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
# The hooks reference is explicit that a hook reaching its 900s timeout in
# .claude/settings.json is CANCELED, its output discarded, and it "renders no
# decision" — and anything that is not exit 2 is a non-blocking error. A gate
# that overruns the hook budget therefore completes the task UNGATED. So this
# gate never trusts the harness to fail closed (ROH-159): every child runs
# under its own bound capped by what remains of an internal budget, and once
# the budget is exhausted the gate stops starting children and renders exit 2
# ITSELF. The per-child bounds may sum past the budget — that is fine, the
# deadline is what encloses the total. The default keeps 60s of margin under
# the hook timeout for kill latency and verdict assembly;
# scripts/test-task-gate.sh pins that arithmetic statically and the deadline
# behavior in a lab. AURA_GATE_BUDGET is the suite's test seam — a non-numeric
# value falls back to the default rather than disarming the deadline.
GATE_BUDGET="${AURA_GATE_BUDGET:-840}"
[[ "$GATE_BUDGET" =~ ^[0-9]+$ ]] || GATE_BUDGET=840
TEST_TIMEOUT=600
LINT_TIMEOUT=300
GUARD_TIMEOUT=60

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$repo" || exit 0

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------- review baseline
# The diff baseline is the shared branch this repo publishes to: origin/HEAD
# first (whatever the remote actually calls its default), then the conventional
# names, then local main/master for repos with no remote at all. A local name
# is a legitimate diff base but proves nothing about what was published — the
# fail-safe below treats it that way.
base="" base_name=""
for cand in origin/HEAD origin/main origin/master main master; do
  if base="$(git rev-parse -q --verify "$cand^{commit}" 2>/dev/null)" && [[ -n "$base" ]]; then
    base_name="$cand"; break
  fi
  base=""
done
head_sha="$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)"
# The published-tip check compares HEAD against EVERY origin candidate, not
# just the first that resolved: a stale origin/HEAD naming a superset branch
# would otherwise pick a baseline that already contains HEAD, silencing the
# three-dot diff and the SHA match at once — reopening the exact hole this
# section closes. Any origin ref equal to HEAD means this state is published.
published_name=""
if [[ -n "$head_sha" ]]; then
  for cand in origin/HEAD origin/main origin/master; do
    if tip="$(git rev-parse -q --verify "$cand^{commit}" 2>/dev/null)" && [[ "$tip" == "$head_sha" ]]; then
      # Name the branch, not the symref, in what the agent reads.
      if [[ "$cand" == origin/HEAD ]] && t="$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)"; then
        cand="${t#refs/remotes/}"
      fi
      published_name="$cand"; break
    fi
  done
fi

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

# ---------------------------------------- published work must not skip (ROH-156)
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
#
# Known residuals, accepted: (a) published-but-uninspected history that later
# commits bury — HEAD strictly ahead of the tip by a follow-up commit, or
# strictly behind after someone else's merge — is not re-inspected here. A
# stateless gate cannot tell inspected-published from uninspected-published
# history, and an ancestor-based trigger would whole-tree-survey every ordinary
# feature branch. (b) sparse checkouts survey index paths that may be absent on
# disk, and the affected child then fails loudly rather than accurately. CI
# covers both.
#
# A repo whose baseline is not an origin ref even though an origin remote
# exists (a single-branch clone of a feature branch; deleted or never-fetched
# origin refs shadowed by a local main) cannot certify "nothing new to verify",
# so it fails safe into the same whole-tree survey. That shadowing would
# otherwise be a one-command silent disable, the ROH-157 class.
fallback=""
if [[ -n "$published_name" ]]; then
  fallback="HEAD is the published tip of $published_name"
elif [[ "$base_name" != origin/* ]] && git remote get-url origin >/dev/null 2>&1; then
  fallback="an origin remote exists but no origin baseline resolves (tried origin/HEAD, origin/main, origin/master)"
fi
if [[ -n "$fallback" ]]; then
  # ls-files -z disables C-quoting entirely (that is the point of -z), so this
  # half needs no dequote pass; the sort -u dedupes it against the survey half.
  files="$({ printf '%s\n' "$files"; git ls-files -z 2>/dev/null | tr '\0' '\n'; } | sed '/^$/d' | sort -u)"
  if [[ -n "$files" ]]; then
    count="$(wc -l <<<"$files" | tr -d ' ')"
    echo "aura-gate: $fallback — surveying the whole tracked tree instead of only the change survey ($count files)." >&2
  fi
fi
if [[ -z "$files" ]]; then
  # A silent no-op is indistinguishable from inspected-and-passed, and only one
  # of those is safe — so the skip says what it skipped and why. The wrapper
  # forwards this on success into the debug log (only exit 2 reaches the agent,
  # and blocking on a benign skip would be worse than the message being quiet).
  if [[ -n "$fallback" ]]; then
    echo "aura-gate: nothing to inspect — the whole-tree survey found no files at all; skipping lint, tests, and guards." >&2
  elif [[ -n "$base" ]]; then
    echo "aura-gate: nothing to inspect — clean tree and no file changes relative to $base_name; skipping lint, tests, and guards." >&2
  else
    echo "aura-gate: nothing to inspect — clean tree and no resolvable baseline; skipping lint, tests, and guards." >&2
  fi
  exit 0
fi

has() { grep -qE "$1" <<<"$files"; }

failures=()
deadline_hit=""

# The perl fallback matters: stock macOS ships neither timeout nor gtimeout, and
# an unbounded swift test is exactly what pushes the hook past ITS timeout, which
# completes the task ungated (see the budget comment above).
tmo() { if have timeout; then timeout "$@"; elif have gtimeout; then gtimeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi; }

run() {  # run <label> <bound-seconds> <dir> <cmd...>
  local label="$1" bound="$2" dir="$3"; shift 3
  # SECONDS is bash's clock since the gate started; the deadline check runs
  # before every child so an exhausted budget becomes a recorded, blocking
  # failure — never a silent harness cancellation.
  local rem=$(( GATE_BUDGET - SECONDS ))
  if (( rem <= 0 )); then
    deadline_hit=1
    failures+=("--- ${label} (not run) ---"$'\n'"the gate's ${GATE_BUDGET}s internal deadline was reached before this step could start")
    return
  fi
  local capped=""
  if (( bound > rem )); then bound=$rem; capped=" — bound capped at ${rem}s by the gate's internal deadline"; fi
  # Never hand tmo a zero or negative bound: `timeout 0` DISABLES the timeout,
  # which would turn an off-by-one at the deadline into an unbounded child.
  (( bound < 1 )) && bound=1
  # Capture through a FILE, not a $(...) pipe. A killed child can leave
  # grandchildren (a test runner's workers) holding the pipe's write end, and a
  # substitution then waits for THEIR exit, not the child's — observed live as
  # a 31s wall on a 2s budget in the suite's deadline lab. A file redirect
  # returns when the direct child exits; orphans append to the file harmlessly.
  # The subshell keeps the cd contained and captures a failed cd as error text.
  local tmp out rc
  tmp="$(mktemp)" || { failures+=("--- ${label} (setup) ---"$'\n'"mktemp failed; cannot capture output"); return; }
  ( cd "$dir" && tmo "$bound" "$@" ) >"$tmp" 2>&1; rc=$?
  out="$(tail -n "$MAX_LINES" "$tmp" 2>/dev/null)"
  rm -f "$tmp"
  [[ $rc -eq 0 ]] && return 0
  failures+=("--- ${label} (exit ${rc})${capped} ---"$'\n'"$out")
}

# ---------------------------------------------------------------------- Swift
# Fail open when the toolchain is missing rather than blocking on a machine that
# was never going to be able to run this.
if has '\.swift$'; then
  # --quiet, or the per-file progress stream is all that survives the tail.
  have swiftlint && run "swiftlint --strict" "$LINT_TIMEOUT" . swiftlint lint --strict --quiet
  have swift && run "swift test --no-parallel" "$TEST_TIMEOUT" AuraCore swift test --no-parallel
fi

# ---------------------------------------------------------------------- guards
# All three are cheap greps over the tree, so they run whenever anything they inspect
# could have moved. The terrain guard also owns the bundled style JSON.
if has '\.swift$'; then
  run "explore rename guard" "$GUARD_TIMEOUT" . bash scripts/check-explore-rename.sh
fi
if has '\.swift$|AuraTerrainStyle\.json$'; then
  run "terrain style guard" "$GUARD_TIMEOUT" . bash scripts/check-terrain-style.sh
fi
if has '\.swift$'; then
  run "single active-time definition" "$GUARD_TIMEOUT" . bash scripts/check-single-active-definition.sh
fi
if has '\.swift$'; then
  run "monotonic instant guard" "$GUARD_TIMEOUT" . bash scripts/check-monotonic-instants.sh
fi
# Keyed to the handoff machinery rather than to Swift: the wrapper, this gate,
# the suite, and the settings file that registers the hook are all pieces whose
# movement can stop the gate running, so any of them moving re-runs the suite
# (which also pins the registration in settings.json). The literal bound stays
# a literal so the suite can pin it statically.
if has 'aura-task-gate\.sh$|test-task-gate\.sh$|\.claude/agent-gate\.sh$|\.claude/settings\.json$'; then
  run "task-gate handoff guard" 120 . bash scripts/test-task-gate.sh
fi

# --------------------------------------------------------------------- verdict
[[ ${#failures[@]} -eq 0 ]] && exit 0

{
  if [[ -n "$fallback" ]]; then
    echo "Task blocked: Aura's quality gate failed on the whole-tree survey ($fallback)."
    echo "The failures below may predate your task — the published tree itself is broken."
    echo
    printf '%s\n\n' "${failures[@]}"
    echo "Fix what you can. If a failure predates your work and cannot be fixed in this"
    echo "task, AURA_SKIP_AGENT_GATE=1 is the documented escape hatch — use it once and"
    echo "say so where the task is tracked, never silently."
  else
    echo "Task blocked: Aura's quality gate failed on your changes."
    echo
    printf '%s\n\n' "${failures[@]}"
    echo "Fix these, re-run the failing command yourself to confirm it passes, then mark"
    echo "the task complete again. Do not disable or work around the gate."
  fi
  if [[ -n "$deadline_hit" ]]; then
    echo
    echo "The gate hit its ${GATE_BUDGET}s internal deadline and blocked rather than let"
    echo "the harness cancel it (a canceled hook renders no decision, and the task would"
    echo "have completed ungated — ROH-159)."
  fi
  echo
  echo "Note this gate does not build the app or run pgTAP. CI still can fail after it passes."
} >&2
exit 2
