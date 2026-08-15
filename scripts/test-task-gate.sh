#!/usr/bin/env bash
# ROH-157: prove .claude/hooks/aura-task-gate.sh only stands aside when the global
# hook will demonstrably run the project gate in its place.
#
# The wrapper's job is one decision: run <repo>/.claude/agent-gate.sh, or let a
# global TaskCompleted hook do it. Getting that wrong toward "stand aside" is
# silent and total — no lint, no tests, no guard scripts, nothing changed in the
# repo, and no message anywhere.
#
# "Stood aside" is therefore observed, never inferred. An absent marker file also
# describes a wrapper that crashed before deciding, so every scenario requires the
# wrapper's own verbose line AND exit 0. The first draft of this suite inferred it
# from absence alone, and stayed green against a wrapper with `exit 1` injected
# into the stand-aside branch.
#
# The lab stubs <repo>/.claude/agent-gate.sh with a recorder, keeping the question
# on the wrapper's decision and off the real gate, which takes minutes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

# A git worktree, a `git rebase --exec`, or any run from inside a git hook exports
# these, and they would make the lab's `git rev-parse` resolve to the REAL repo —
# whose gate now runs this script. That is unbounded recursion, so it is cut here
# rather than left to whatever the ambient environment happens to be.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

WRAPPER="$PWD/.claude/hooks/aura-task-gate.sh"
[[ -x "$WRAPPER" ]] || { echo "FAIL: $WRAPPER missing or not executable"; exit 2; }

LAB="$(mktemp -d)"
trap 'rm -rf "$LAB"' EXIT
failures=0

pass() { printf '  ok    %-52s %s\n' "$1" "$2"; }
fail() { printf '  FAIL  %-52s %s\n' "$1" "$2"; failures=$((failures + 1)); }

# Builds a throwaway repo whose project gate records that it ran and exits $1.
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

# $1 = the global hook's shape, $2 = how (and whether) it is registered.
make_home() {
  local hook="$1" reg="$2" home="$LAB/home" h
  rm -rf "$home"; mkdir -p "$home/.claude/hooks"
  h="$home/.claude/hooks/agent-gate.sh"

  case "$hook" in
    absent) ;;
    empty)      : >"$h"; chmod +x "$h" ;;
    nonexec)    printf '#!/bin/sh\nexec ./.claude/agent-gate.sh\n' >"$h"; chmod -x "$h" ;;
    nodelegate) printf '#!/bin/sh\nswiftlint lint --strict\n' >"$h"; chmod +x "$h" ;;
    # Names the project gate only in prose. The stock global hook's header does
    # exactly this, so a copy that keeps the comment and drops the code lands here.
    commentonly)
      printf '#!/bin/sh\n# Used to exec ./.claude/agent-gate.sh; disabled for now.\nexit 0\n' >"$h"
      chmod +x "$h" ;;
    executable) printf '#!/bin/sh\nexec ./.claude/agent-gate.sh\n' >"$h"; chmod +x "$h" ;;
  esac

  local cmd
  case "$reg" in
    none) ;;
    settings) cmd='{"command":"~/.claude/hooks/agent-gate.sh"}' ;;
    # The exec form the hook docs recommend for path placeholders.
    execform) cmd='{"command":"bash","args":["~/.claude/hooks/agent-gate.sh"]}' ;;
    # Registered, but pointing at a different file. The hook above is a leftover.
    otherpath) cmd='{"command":"/opt/nonexistent/other-agent-gate.sh"}' ;;
    # Registered as a no-op that merely mentions the name.
    noop) cmd='{"command":"true # agent-gate.sh disabled 2026-08"}' ;;
  esac

  if [[ -n "${cmd:-}" ]]; then
    printf '{"hooks":{"TaskCompleted":[{"hooks":[%s]}]}}\n' "$cmd" >"$home/.claude/settings.json"
  fi
  case "$reg" in
    # A user-scope settings.local.json is not a documented hook source, so the
    # wrapper does not trust one. If Claude Code does load it, the cost is a
    # duplicate run, which the gate's own dedupe absorbs.
    local) printf '{"hooks":{"TaskCompleted":[{"hooks":[{"command":"~/.claude/hooks/agent-gate.sh"}]}]}}\n' \
             >"$home/.claude/settings.local.json" ;;
    # Registered, but under a different event, so it never fires on TaskCompleted.
    otherevent) printf '{"hooks":{"PostToolUse":[{"hooks":[{"command":"~/.claude/hooks/agent-gate.sh"}]}]}}\n' \
             >"$home/.claude/settings.json" ;;
  esac
  printf '%s\n' "$home"
}

# A PATH whose python3 exits non-zero, standing in for any reason the registration
# cannot be read. A genuinely absent interpreter takes a different branch and is
# covered separately below.
broken_python_path() {
  local bin="$LAB/brokenbin"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 1\n' >"$bin/python3"; chmod +x "$bin/python3"
  printf '%s\n' "$bin:$PATH"
}

# scenario <name> <hook> <reg> <expect: ran|aside> [path]
scenario() {
  local name="$1" hook="$2" reg="$3" expect="$4" path="${5:-$PATH}"
  local repo home rc err actual
  repo="$(make_repo 0)"; home="$(make_home "$hook" "$reg")"
  rm -f "$LAB/PROJECT_GATE_RAN"

  err="$( cd "$repo" && HOME="$home" PATH="$path" AURA_GATE_VERBOSE=1 \
          ./.claude/hooks/aura-task-gate.sh </dev/null 2>&1 >/dev/null )"
  rc=$?

  if [[ -e "$LAB/PROJECT_GATE_RAN" ]]; then
    actual="ran"
  elif grep -q "standing aside" <<<"$err"; then
    actual="aside"
  else
    # Neither happened: the wrapper exited without making a decision. Absence of
    # the marker alone would have scored this as a correct "aside".
    actual="undecided"
  fi

  if [[ "$actual" != "$expect" ]]; then
    fail "$name" "expected $expect, got $actual (exit $rc)"
  elif [[ $rc -ne 0 ]]; then
    fail "$name" "decided $actual but exited $rc, not 0"
  else
    pass "$name" "$actual"
  fi
}

echo "aura-task-gate.sh — stand-aside decision"

# The four rows ROH-157 reproduced.
scenario "no global hook"                           absent      none      ran
scenario "executable but registered nowhere"        executable  none      ran
scenario "present but not executable"               nonexec     settings  ran
scenario "zero-byte executable, registered nowhere" empty       none      ran

# Registration alone is not enough: a registered global hook that never delegates
# leaves the project gate unrun, and its built-in path runs a bare `swift test`
# rather than this repo's --no-parallel plus five guard scripts.
scenario "registered but does not delegate"         nodelegate  settings  ran
scenario "names the project gate only in a comment" commentonly settings  ran

# Registration has to name THIS file. A stale delegating copy at the canonical path
# plus a settings entry pointing elsewhere was ROH-157 through a second door.
scenario "delegating leftover, another path wired"  executable  otherpath ran
scenario "registration is a no-op naming the file"  executable  noop      ran
scenario "registered under a different event"       executable otherevent ran
scenario "user settings.local.json is not trusted"  executable  local     ran

# The cases actually worth standing aside for.
scenario "registered in settings.json, delegates"   executable  settings  aside
scenario "registered in the exec form, delegates"   executable  execform  aside

# Every uncertainty runs the gate.
scenario "delegates but no settings file at all"    executable  none      ran
scenario "registration unparseable"                 executable  settings  ran "$(broken_python_path)"

echo "aura-task-gate.sh — hook protocol"

# The header calls the stdin drain load-bearing. Assert it: whatever the wrapper
# leaves unread is still there for the next reader.
run_drain() {
  local repo home leftover
  repo="$(make_repo 0)"; home="$(make_home absent none)"
  rm -f "$LAB/PROJECT_GATE_RAN"
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
  repo="$(make_repo 1)"; home="$(make_home absent none)"
  rm -f "$LAB/PROJECT_GATE_RAN"
  out="$( cd "$repo" && HOME="$home" ./.claude/hooks/aura-task-gate.sh </dev/null 2>&1 >/dev/null )"
  rc=$?
  if [[ $rc -eq 2 ]] && grep -q "stub gate output" <<<"$out"; then
    pass "failing project gate blocks" "exit 2, stderr forwarded"
  else
    fail "failing project gate blocks" "expected exit 2 with output, got $rc: $out"
  fi
}
run_failing_gate

# Outside a repo there is nothing to gate: fail open rather than block a task.
run_outside_repo() {
  local home rc dir="$LAB/notarepo" repo
  repo="$(make_repo 0)"; mkdir -p "$dir"; home="$(make_home absent none)"
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

# HOME unset must not abort under `set -u`: that exits non-zero without deciding,
# and a TaskCompleted hook exiting 1 lets the task through ungated.
run_home_unset() {
  local repo rc
  repo="$(make_repo 0)"; rm -f "$LAB/PROJECT_GATE_RAN"
  ( cd "$repo" && env -u HOME ./.claude/hooks/aura-task-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ -e "$LAB/PROJECT_GATE_RAN" && $rc -eq 0 ]]; then
    pass "HOME unset still runs the gate" "exit 0"
  else
    fail "HOME unset still runs the gate" "gate ran=$([[ -e $LAB/PROJECT_GATE_RAN ]] && echo yes || echo no), exit $rc"
  fi
}
run_home_unset

echo
if [[ $failures -eq 0 ]]; then echo "PASS"; exit 0; fi
echo "FAIL: $failures scenario(s)"
exit 1
