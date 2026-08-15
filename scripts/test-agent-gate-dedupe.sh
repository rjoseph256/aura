#!/usr/bin/env bash
# ROH-157: prove .claude/agent-gate.sh runs its checks once per tree, and that a
# second gate reaching the same tree replays the first one's verdict.
#
# Two things bring a second copy of the gate to one repo for one event:
#
#   Nested — the gate runs scripts/test-task-gate.sh, which runs a copy of the
#   task-gate wrapper, which resolves a repo and can arrive back at the gate.
#   Unbounded, and each level costs a full lint-and-test pass.
#
#   Sibling — a machine with the global hook installed has two TaskCompleted hooks
#   registered, and Claude Code runs matching hooks in parallel. Unrelated
#   processes, so no environment variable can see across them.
#
# The lab copies the REAL gate into a throwaway repo, commits everything, then
# dirties only a task-gate wrapper and a nonce — so the gate selects its
# handoff-guard branch and no other. That branch is stubbed to a recorder, which
# keeps each run cheap while still exercising the fingerprint, the lock, the cache
# and the verdict path for real.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset AURA_GATE_RUNNING AURA_SKIP_AGENT_GATE

GATE_SRC="$PWD/.claude/agent-gate.sh"
[[ -x "$GATE_SRC" ]] || { echo "FAIL: $GATE_SRC missing or not executable"; exit 2; }

LAB="$(mktemp -d)"
export TMPDIR="$LAB/tmp"; mkdir -p "$TMPDIR"   # keep cache/lock files inside the lab
trap 'rm -rf "$LAB"' EXIT
failures=0
pass() { printf '  ok    %-52s %s\n' "$1" "$2"; }
fail() { printf '  FAIL  %-52s %s\n' "$1" "$2"; failures=$((failures + 1)); }

TALLY="$LAB/CHECKS_RAN"
SEQ_FILE="$LAB/seq"

# $1 = exit code the stubbed guard returns.
#
# Each call produces a DIFFERENT tree. Without the nonce every scenario builds
# byte-identical content at the same path, so they all share one fingerprint and
# every scenario after the first replays the first one's verdict — which reads as
# "the checks never ran" and hides whatever the scenario meant to test.
#
# The counter lives on disk because every call site is `$(make_repo ...)`, and a
# command substitution is a subshell: an ordinary variable would be incremented in
# a child and reset on the next call, leaving every nonce identical.
make_repo() {
  local rc="${1:-0}" repo="$LAB/repo" n
  n=$(( $(cat "$SEQ_FILE" 2>/dev/null || echo 0) + 1 )); printf '%d\n' "$n" >"$SEQ_FILE"
  rm -rf "$repo"; mkdir -p "$repo/.claude/hooks" "$repo/scripts"
  git -C "$repo" init -q
  cp "$GATE_SRC" "$repo/.claude/agent-gate.sh"; chmod +x "$repo/.claude/agent-gate.sh"
  printf '#!/bin/sh\nexit 0\n' >"$repo/.claude/hooks/aura-task-gate.sh"
  cat >"$repo/scripts/test-task-gate.sh" <<EOF
#!/usr/bin/env bash
echo ran >> "$TALLY"
echo "stub check output"
exit $rc
EOF
  chmod +x "$repo/scripts/test-task-gate.sh"

  # Committed first, so the gate's own copy is TRACKED AND CLEAN. Left dirty it
  # matches the gate's `agent-gate\.sh$` trigger, and the lab would try to run a
  # dedupe guard that does not exist here — the lab's checks are meant to be one
  # cheap stub, not whatever the real gate's branches happen to select.
  git -C "$repo" add -A
  git -C "$repo" -c user.email=lab@example.invalid -c user.name=lab commit -q -m init

  # Now dirty exactly the two files that select the handoff branch and nothing
  # else. The nonce makes each scenario a distinct tree; without it they share a
  # fingerprint and every scenario after the first replays the first one's verdict.
  printf 'scenario %d\n' "$n" >"$repo/nonce.txt"
  printf '# scenario %d\n' "$n" >>"$repo/.claude/hooks/aura-task-gate.sh"
  printf '%s\n' "$repo"
}

# Runs the gate with a deadline, since `timeout` is not present on a stock macOS.
# Sets `rc`, or `rc=124` if it had to be killed.
gate_with_deadline() {
  local repo="$1" limit="${2:-25}" pid elapsed=0
  ( cd "$repo" && ./.claude/agent-gate.sh </dev/null >/dev/null 2>&1 ) & pid=$!
  while kill -0 "$pid" 2>/dev/null && [[ $elapsed -lt $limit ]]; do sleep 1; elapsed=$((elapsed + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=124
  else
    wait "$pid"; rc=$?
  fi
}

runs() { [[ -f "$TALLY" ]] && wc -l <"$TALLY" | tr -d ' ' || echo 0; }

echo "agent-gate.sh — run-once semantics"

# A clean run does the work and passes.
repo="$(make_repo 0)"; : >"$TALLY"
( cd "$repo" && ./.claude/agent-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
if [[ $rc -eq 0 && "$(runs)" == 1 ]]; then pass "first run executes the checks" "exit 0, 1 execution"
else fail "first run executes the checks" "exit $rc, $(runs) execution(s)"; fi

# Same tree again: the verdict is already known, so the checks must not rerun.
( cd "$repo" && ./.claude/agent-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
if [[ $rc -eq 0 && "$(runs)" == 1 ]]; then pass "second run on the same tree replays" "exit 0, still 1 execution"
else fail "second run on the same tree replays" "exit $rc, $(runs) execution(s)"; fi

# A changed tree is a different question and must be asked again. Content, not the
# path list: the same file edited twice has an identical `git status` line.
printf 'edit\n' >>"$repo/.claude/hooks/aura-task-gate.sh"
( cd "$repo" && ./.claude/agent-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
if [[ $rc -eq 0 && "$(runs)" == 2 ]]; then pass "a changed tree re-runs the checks" "exit 0, 2 executions"
else fail "a changed tree re-runs the checks" "exit $rc, $(runs) execution(s)"; fi

echo "agent-gate.sh — re-entrancy"

# A nested gate must stand down instantly, or the wrapper/test/gate chain is
# unbounded and each level pays for a full pass.
repo="$(make_repo 0)"; : >"$TALLY"
( cd "$repo" && AURA_GATE_RUNNING=1 ./.claude/agent-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
if [[ $rc -eq 0 && "$(runs)" == 0 ]]; then pass "nested run does nothing" "exit 0, 0 executions"
else fail "nested run does nothing" "exit $rc, $(runs) execution(s)"; fi

echo "agent-gate.sh — verdict is preserved, not just the pass"

# A failure must survive the replay. Replaying only successes would turn the
# dedupe into a way to launder a red gate green.
repo="$(make_repo 1)"; : >"$TALLY"
out="$( cd "$repo" && ./.claude/agent-gate.sh </dev/null 2>&1 >/dev/null )"; rc=$?
if [[ $rc -eq 2 && "$(runs)" == 1 ]] && grep -q "stub check output" <<<"$out"; then pass "a failing check blocks" "exit 2, reason forwarded"
else fail "a failing check blocks" "exit $rc, $(runs) run(s): $out"; fi

out="$( cd "$repo" && ./.claude/agent-gate.sh </dev/null 2>&1 >/dev/null )"; rc=$?
if [[ $rc -eq 2 && "$(runs)" == 1 ]] && grep -q "stub check output" <<<"$out"; then pass "the replayed verdict is still a failure" "exit 2, still 1 execution"
else fail "the replayed verdict is still a failure" "exit $rc, $(runs) run(s): $out"; fi

echo "agent-gate.sh — concurrent siblings"

# Two gates started together on one tree: one does the work, the other waits for
# its answer. Both must agree, and the checks must run once.
repo="$(make_repo 0)"; : >"$TALLY"
( cd "$repo" && ./.claude/agent-gate.sh </dev/null >/dev/null 2>&1 ) & p1=$!
( cd "$repo" && ./.claude/agent-gate.sh </dev/null >/dev/null 2>&1 ) & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
if [[ $r1 -eq 0 && $r2 -eq 0 && "$(runs)" == 1 ]]; then pass "parallel gates execute the checks once" "both exit 0, 1 execution"
else fail "parallel gates execute the checks once" "exits $r1/$r2, $(runs) execution(s)"; fi

# A lock whose owner was killed outright is never cleaned by the EXIT trap. The
# gate must reclaim it rather than wait out LOCK_WAIT, and must still run the
# checks rather than pass a task on the strength of a verdict nobody recorded.
repo="$(make_repo 0)"; : >"$TALLY"
# Cleared first so the cache file found below is unambiguously this repo's. Picking
# the first of many left by earlier scenarios backdates a lock for some other
# fingerprint, while this tree's verdict survives and quietly replays.
rm -f "$TMPDIR"/aura-gate-*
gate_with_deadline "$repo"
stale="$(find "$TMPDIR" -maxdepth 1 -name 'aura-gate-*' -not -name '*.lock' | head -1)"
if [[ -n "$stale" ]]; then
  rm -f "$stale"; mkdir -p "$stale.lock"
  touch -t 202601010000 "$stale.lock"   # older than the verdict TTL
  : >"$TALLY"
  gate_with_deadline "$repo"
  rmdir "$stale.lock" 2>/dev/null
  if [[ $rc -eq 0 && "$(runs)" == 1 ]]; then
    pass "abandoned lock is reclaimed" "exit 0, checks ran once"
  elif [[ $rc -eq 124 ]]; then
    fail "abandoned lock is reclaimed" "waited out the deadline instead of reclaiming"
  else
    fail "abandoned lock is reclaimed" "exit $rc, $(runs) execution(s)"
  fi
else
  fail "abandoned lock is reclaimed" "no cache file was written to inspect"
fi

echo
if [[ $failures -eq 0 ]]; then echo "PASS"; exit 0; fi
echo "FAIL: $failures scenario(s)"
exit 1
