#!/usr/bin/env bash
# ROH-157: prove .claude/hooks/aura-task-gate.sh always runs the project gate.
#
# It used to stand aside whenever an executable file existed at
# ~/.claude/hooks/agent-gate.sh, on the theory that a global hook there would run
# the project gate instead. A zero-byte file was enough to satisfy that, so Aura's
# gate silently stopped running: no lint, no tests, no guard scripts, nothing
# changed in the repo, and no message anywhere.
#
# The fix deleted the decision rather than improving it, so what needs pinning is
# an absence: no arrangement of that path, and no settings file, makes the wrapper
# skip the gate. Every scenario below therefore expects the gate to RUN, and the
# suite exists to fail the moment someone reintroduces a stand-aside branch.
#
# "Ran" is observed through a stubbed project gate that records its own invocation,
# never inferred from the wrapper's exit code — a wrapper that dies before doing
# anything also exits without running the gate, and the two must not look alike.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

# A worktree, a `git rebase --exec`, or a run from inside a git hook exports these,
# and they would make the lab's `git rev-parse` resolve to the REAL repo, whose
# gate runs this script. That is a recursion this suite must not depend on luck to
# avoid. CLAUDE_CONFIG_DIR is cleared for the same reason: it would let the ambient
# environment reach past the lab's synthetic HOME.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset CLAUDE_CONFIG_DIR
# Ambient git configuration is another way in: GIT_CONFIG_GLOBAL / _SYSTEM /
# _COUNT and XDG_CONFIG_HOME all reach the lab's git invocations no matter what
# HOME is set to.
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT XDG_CONFIG_HOME

WRAPPER="$PWD/.claude/hooks/aura-task-gate.sh"
[[ -x "$WRAPPER" ]] || { echo "FAIL: $WRAPPER missing or not executable"; exit 2; }

LAB="$(mktemp -d)"
trap 'rm -rf "$LAB"' EXIT
# If TMPDIR ever sits inside a git repo, discovery from $LAB/notarepo would walk
# up out of the lab and find that repo — and run whatever gate it carries. The
# ceiling stops discovery at the lab boundary. (Verified: without it, a repo
# enclosing TMPDIR is found; with it, rev-parse fails as the suite expects.)
export GIT_CEILING_DIRECTORIES="$LAB"
failures=0
pass() { printf '  ok    %-50s %s\n' "$1" "$2"; }
fail() { printf '  FAIL  %-50s %s\n' "$1" "$2"; failures=$((failures + 1)); }

# A throwaway repo whose project gate records that it ran and exits $1.
make_repo() {
  local rc="${1:-0}" repo="$LAB/repo"
  rm -rf "$repo"; mkdir -p "$repo/.claude/hooks"
  git -C "$repo" init -q
  cp "$WRAPPER" "$repo/.claude/hooks/aura-task-gate.sh"
  chmod +x "$repo/.claude/hooks/aura-task-gate.sh"
  cat >"$repo/.claude/agent-gate.sh" <<EOF
#!/usr/bin/env bash
touch "$LAB/PROJECT_GATE_RAN"
echo "stub gate output"
exit $rc
EOF
  chmod +x "$repo/.claude/agent-gate.sh"
  printf '%s\n' "$repo"
}

# $1 = the global hook's shape, $2 = whether a settings file registers it.
make_home() {
  local hook="$1" reg="$2" home="$LAB/home" h
  rm -rf "$home"; mkdir -p "$home/.claude/hooks"
  h="$home/.claude/hooks/agent-gate.sh"
  case "$hook" in
    absent) ;;
    empty)      : >"$h"; chmod +x "$h" ;;
    nonexec)    printf '#!/bin/sh\nexec ./.claude/agent-gate.sh\n' >"$h"; chmod -x "$h" ;;
    delegating) printf '#!/bin/sh\nexec ./.claude/agent-gate.sh\n' >"$h"; chmod +x "$h" ;;
  esac
  if [[ "$reg" == registered ]]; then
    printf '{"hooks":{"TaskCompleted":[{"hooks":[{"command":"~/.claude/hooks/agent-gate.sh"}]}]}}\n' \
      >"$home/.claude/settings.json"
  fi
  printf '%s\n' "$home"
}

# scenario <name> <hook> <reg>
scenario() {
  local name="$1" hook="$2" reg="$3" repo home rc
  repo="$(make_repo 0)"; home="$(make_home "$hook" "$reg")"
  rm -f "$LAB/PROJECT_GATE_RAN"
  ( cd "$repo" && HOME="$home" ./.claude/hooks/aura-task-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ ! -e "$LAB/PROJECT_GATE_RAN" ]]; then
    fail "$name" "the gate did not run (exit $rc)"
  elif [[ $rc -ne 0 ]]; then
    fail "$name" "gate ran but the wrapper exited $rc, not 0"
  else
    pass "$name" "gate ran"
  fi
}

echo "aura-task-gate.sh — the gate always runs"

# The four shapes ROH-157 reproduced. Two of them used to skip the gate entirely;
# the last is the one that made a stand-aside look reasonable in the first place.
scenario "no global hook"                            absent     unregistered
scenario "executable global hook, unregistered"      delegating unregistered
scenario "global hook present but not executable"    nonexec    registered
scenario "zero-byte executable global hook"          empty      unregistered
scenario "global hook registered AND delegating"     delegating registered

echo "aura-task-gate.sh — hook protocol"

# The header calls the stdin drain load-bearing. Assert it: whatever the wrapper
# leaves unread would still be waiting for the next reader.
run_drain() {
  local repo home leftover
  repo="$(make_repo 0)"; home="$(make_home absent unregistered)"
  leftover="$( cd "$repo" && printf 'HOOK_PAYLOAD_JSON\n' |
    { HOME="$home" ./.claude/hooks/aura-task-gate.sh >/dev/null 2>&1; cat; } )"
  if [[ -z "$leftover" ]]; then
    pass "stdin payload is drained" "nothing left for the next reader"
  else
    fail "stdin payload is drained" "left behind: $leftover"
  fi
}
run_drain

# A failing project gate has to block, and say why.
run_failing_gate() {
  local repo home out rc
  repo="$(make_repo 1)"; home="$(make_home absent unregistered)"
  out="$( cd "$repo" && HOME="$home" ./.claude/hooks/aura-task-gate.sh </dev/null 2>&1 >/dev/null )"; rc=$?
  if [[ $rc -eq 2 ]] && grep -q "stub gate output" <<<"$out"; then
    pass "a failing project gate blocks" "exit 2, stderr forwarded"
  else
    fail "a failing project gate blocks" "expected exit 2 with output, got $rc: $out"
  fi
}
run_failing_gate

# Outside a repo there is nothing to gate: fail open rather than block a task.
run_outside_repo() {
  local home rc repo dir="$LAB/notarepo"
  repo="$(make_repo 0)"; mkdir -p "$dir"; home="$(make_home absent unregistered)"
  # The lab's copy, not the live one: the live wrapper would find the real repo if
  # mktemp ever landed inside one, and the real gate runs this script.
  ( cd "$dir" && HOME="$home" "$repo/.claude/hooks/aura-task-gate.sh" </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "outside a git repo, fails open" "exit 0"
  else
    fail "outside a git repo, fails open" "expected exit 0, got $rc"
  fi
}
run_outside_repo

# `set -u` plus an unset HOME used to abort the wrapper before it decided anything,
# and a TaskCompleted hook exiting 1 lets the task through ungated.
run_home_unset() {
  local repo rc
  repo="$(make_repo 0)"; rm -f "$LAB/PROJECT_GATE_RAN"
  ( cd "$repo" && env -u HOME ./.claude/hooks/aura-task-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ -e "$LAB/PROJECT_GATE_RAN" && $rc -eq 0 ]]; then
    pass "HOME unset still runs the gate" "exit 0"
  else
    fail "HOME unset still runs the gate" "ran=$([[ -e $LAB/PROJECT_GATE_RAN ]] && echo yes || echo no), exit $rc"
  fi
}
run_home_unset

echo
if [[ $failures -eq 0 ]]; then echo "PASS"; exit 0; fi
echo "FAIL: $failures scenario(s)"
exit 1
