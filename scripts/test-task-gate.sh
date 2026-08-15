#!/usr/bin/env bash
# ROH-157: prove .claude/hooks/aura-task-gate.sh only stands aside when the global
# hook will demonstrably run the project gate in its place.
#
# The wrapper's job is one decision: run <repo>/.claude/agent-gate.sh, or let a
# global TaskCompleted hook do it. Getting that wrong in the "stand aside"
# direction is silent and total — no lint, no tests, no guard scripts, nothing in
# the repo changed, and no message anywhere. So every scenario below asserts which
# way the decision went, not merely that the hook exited 0.
#
# The lab stubs <repo>/.claude/agent-gate.sh with a script that records that it ran.
# That keeps the question to the wrapper's decision and off the real gate, which
# takes minutes. Exit-code propagation is covered separately at the end.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

WRAPPER="$PWD/.claude/hooks/aura-task-gate.sh"
[[ -x "$WRAPPER" ]] || { echo "FAIL: $WRAPPER missing or not executable"; exit 2; }

LAB="$(mktemp -d)"
trap 'rm -rf "$LAB"' EXIT
failures=0

# Builds a throwaway repo whose project gate records its invocation and exits $1.
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

# Builds a synthetic HOME. $1 = global hook state, $2 = where it is registered.
#   hook:  absent | executable | nonexec | empty | nodelegate
#   reg:   none | settings | local
make_home() {
  local hook="$1" reg="$2" home="$LAB/home"
  rm -rf "$home"; mkdir -p "$home/.claude/hooks"

  case "$hook" in
    absent) ;;
    empty)  : >"$home/.claude/hooks/agent-gate.sh"; chmod +x "$home/.claude/hooks/agent-gate.sh" ;;
    nonexec)
      printf '#!/bin/sh\nexec ./.claude/agent-gate.sh\n' >"$home/.claude/hooks/agent-gate.sh"
      chmod -x "$home/.claude/hooks/agent-gate.sh" ;;
    nodelegate)
      printf '#!/bin/sh\nswiftlint lint --strict\n' >"$home/.claude/hooks/agent-gate.sh"
      chmod +x "$home/.claude/hooks/agent-gate.sh" ;;
    executable)
      printf '#!/bin/sh\nexec ./.claude/agent-gate.sh\n' >"$home/.claude/hooks/agent-gate.sh"
      chmod +x "$home/.claude/hooks/agent-gate.sh" ;;
  esac

  local json='{"hooks":{"TaskCompleted":[{"hooks":[{"type":"command","command":"~/.claude/hooks/agent-gate.sh"}]}]}}'
  case "$reg" in
    none)     ;;
    settings) printf '%s\n' "$json" >"$home/.claude/settings.json" ;;
    local)    printf '%s\n' "$json" >"$home/.claude/settings.local.json" ;;
  esac
  printf '%s\n' "$home"
}

# A PATH whose python3 is present but broken, for the "cannot parse registration"
# case. Covers a genuinely missing interpreter too: both end in a non-zero parse.
broken_python_path() {
  local bin="$LAB/brokenbin"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 1\n' >"$bin/python3"
  chmod +x "$bin/python3"
  printf '%s\n' "$bin:$PATH"
}

# scenario <name> <hook> <reg> <expect: ran|aside> [path]
scenario() {
  local name="$1" hook="$2" reg="$3" expect="$4" path="${5:-$PATH}"
  local repo home rc
  repo="$(make_repo 0)"; home="$(make_home "$hook" "$reg")"
  rm -f "$LAB/PROJECT_GATE_RAN"

  ( cd "$repo" && HOME="$home" PATH="$path" ./.claude/hooks/aura-task-gate.sh </dev/null >/dev/null 2>&1 )
  rc=$?

  local actual="aside"
  [[ -e "$LAB/PROJECT_GATE_RAN" ]] && actual="ran"

  if [[ "$actual" == "$expect" ]]; then
    printf '  ok    %-58s %s\n' "$name" "$actual"
  else
    printf '  FAIL  %-58s expected %s, got %s (hook exit %d)\n' "$name" "$expect" "$actual" "$rc"
    failures=$((failures + 1))
  fi
}

echo "aura-task-gate.sh — stand-aside decision"

# The four rows ROH-157 reproduced. Rows 2 and 4 are the defect.
scenario "no global hook"                          absent     none     ran
scenario "executable but registered nowhere"       executable none     ran
scenario "present but not executable"              nonexec    settings ran
scenario "zero-byte executable, registered nowhere" empty     none     ran

# Registration alone is not enough: a registered global hook that never delegates
# leaves the project gate unrun, and the built-in fallback runs a bare `swift test`
# rather than this repo's `--no-parallel` plus its four guard scripts.
scenario "registered but does not delegate"        nodelegate settings ran

# A registered, delegating global hook is the one case worth standing aside for.
scenario "registered in settings.json, delegates"  executable settings aside
scenario "registered in settings.local.json"       executable local    aside

# Registered somewhere unreadable is not registered.
scenario "delegates but no settings file at all"   executable none     ran

# Every uncertainty runs the gate. If registration cannot be read — no interpreter,
# a broken one, malformed JSON — the answer is "run it", never "assume covered".
scenario "registration unparseable, otherwise valid" executable settings ran "$(broken_python_path)"

echo "aura-task-gate.sh — exit contract"

# A failing project gate has to block, and say why.
run_failing_gate() {
  local repo home out rc
  repo="$(make_repo 1)"; home="$(make_home absent none)"
  rm -f "$LAB/PROJECT_GATE_RAN"
  out="$( cd "$repo" && HOME="$home" ./.claude/hooks/aura-task-gate.sh </dev/null 2>&1 >/dev/null )"
  rc=$?
  if [[ $rc -eq 2 ]] && grep -q "stub gate output" <<<"$out"; then
    printf '  ok    %-58s blocked, stderr forwarded\n' "failing project gate blocks"
  else
    printf '  FAIL  %-58s expected exit 2 with output, got %d: %s\n' "failing project gate blocks" "$rc" "$out"
    failures=$((failures + 1))
  fi
}
run_failing_gate

# Outside a repo there is nothing to gate: fail open rather than block a task.
run_outside_repo() {
  local home rc dir="$LAB/notarepo"
  mkdir -p "$dir"; home="$(make_home absent none)"
  ( cd "$dir" && HOME="$home" "$WRAPPER" </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '  ok    %-58s exit 0\n' "outside a git repo, fails open"
  else
    printf '  FAIL  %-58s expected exit 0, got %d\n' "outside a git repo, fails open" "$rc"
    failures=$((failures + 1))
  fi
}
run_outside_repo

echo
if [[ $failures -eq 0 ]]; then
  echo "PASS"
  exit 0
fi
echo "FAIL: $failures scenario(s)"
exit 1
