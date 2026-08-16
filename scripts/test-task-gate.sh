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
# an absence: no arrangement of that path, no settings file, no lost executable
# bit on the gate makes the wrapper skip it. Inside an Aura-shaped repo the gate
# runs or the task is blocked loudly; the suite exists to fail the moment someone
# reintroduces a silent exit.
#
# "Ran" is observed through a stubbed project gate that records its own invocation,
# never inferred from the wrapper's exit code — a wrapper that dies before doing
# anything also exits without running the gate, and the two must not look alike.
# The stub honours AURA_SKIP_AGENT_GATE the way the real gate does, so a wrapper
# that injects the escape hatch into the gate's environment reads as "did not run".
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

# Exported GIT_* variables (a `git rebase --exec`, a run from inside a git hook,
# tooling that sets GIT_DIR) would make the lab's `git rev-parse` resolve to the
# REAL repo, whose gate runs this script. That is a recursion this suite must not
# depend on luck to avoid. CLAUDE_CONFIG_DIR would let the ambient environment
# reach past the lab's synthetic HOME, and the skip variables would blind the
# stub gates. All defensive, all cheap.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset CLAUDE_CONFIG_DIR CLAUDE_PROJECT_DIR
unset AURA_SKIP_AGENT_GATE CLAUDE_SKIP_AGENT_GATE
# Ambient git configuration is another way in: GIT_CONFIG_GLOBAL / _SYSTEM /
# _COUNT and XDG_CONFIG_HOME all reach the lab's git invocations no matter what
# HOME is set to.
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT XDG_CONFIG_HOME

WRAPPER="$PWD/.claude/hooks/aura-task-gate.sh"
[[ -f "$WRAPPER" ]] || { echo "FAIL: $WRAPPER missing"; exit 2; }

LAB="$(mktemp -d)" && [[ -d "$LAB" ]] || { echo "FAIL: mktemp -d failed"; exit 2; }
trap 'rm -rf "$LAB"' EXIT
# If TMPDIR ever sits inside a git repo (Linux mktemp honours TMPDIR; macOS
# usually pins it elsewhere), discovery from $LAB/notarepo would walk up out of
# the lab, find that repo, and run whatever gate it carries. The ceiling stops
# discovery at the lab boundary; probed directly: with an enclosing repo around
# the lab, rev-parse fails inside it exactly as the scenarios assume.
export GIT_CEILING_DIRECTORIES="$LAB"
failures=0
pass() { printf '  ok    %-50s %s\n' "$1" "$2"; }
fail() { printf '  FAIL  %-50s %s\n' "$1" "$2"; failures=$((failures + 1)); }

# The registration is the most fragile link: if .claude/settings.json stops
# declaring the wrapper as a TaskCompleted hook, nothing below ever runs again on
# a fresh session, and no lab scenario can see that. Pin the real file.
check_registration() {
  local ok
  ok="$(python3 - <<'EOF' 2>/dev/null
import json
cfg = json.load(open(".claude/settings.json"))
cmds = [h.get("command", "")
        for m in cfg.get("hooks", {}).get("TaskCompleted", [])
        for h in m.get("hooks", [])]
hit = [c for c in cmds if "aura-task-gate.sh" in c]
print("ok" if hit and all(c.strip().startswith("bash ") for c in hit) else "bad")
EOF
)"
  if [[ "$ok" == ok ]]; then
    pass "settings.json registers the wrapper" "TaskCompleted -> bash aura-task-gate.sh"
  else
    fail "settings.json registers the wrapper" "no bash-invoked TaskCompleted entry names aura-task-gate.sh"
  fi
}

# A throwaway repo whose project gate records that it ran and exits $1.
# gate_mode: exec (default), nonexec, or missing.
make_repo() {
  local rc="${1:-0}" gate_mode="${2:-exec}" repo="${LAB:?}/repo"
  rm -rf "$repo"; mkdir -p "$repo/.claude/hooks"
  git -C "$repo" init -q
  cp "$WRAPPER" "$repo/.claude/hooks/aura-task-gate.sh"
  chmod +x "$repo/.claude/hooks/aura-task-gate.sh"
  if [[ "$gate_mode" != missing ]]; then
    cat >"$repo/.claude/agent-gate.sh" <<EOF
#!/usr/bin/env bash
[[ -n "\${AURA_SKIP_AGENT_GATE:-}" ]] && exit 0
touch "${LAB:?}/PROJECT_GATE_RAN"
echo "stub gate output"
exit $rc
EOF
    if [[ "$gate_mode" == nonexec ]]; then chmod -x "$repo/.claude/agent-gate.sh"
    else chmod +x "$repo/.claude/agent-gate.sh"; fi
  fi
  printf '%s\n' "$repo"
}

# $1 = the global hook's shape, $2 = whether a settings file registers it.
make_home() {
  local hook="$1" reg="$2" home="${LAB:?}/home" h
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

# scenario <name> <hook> <reg> [extra env assignments...]
scenario() {
  local name="$1" hook="$2" reg="$3"; shift 3
  local repo home rc
  repo="$(make_repo 0)"; home="$(make_home "$hook" "$reg")"
  rm -f "$LAB/PROJECT_GATE_RAN"
  ( cd "$repo" && env HOME="$home" "$@" bash ./.claude/hooks/aura-task-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ ! -e "$LAB/PROJECT_GATE_RAN" ]]; then
    fail "$name" "the gate did not run (exit $rc)"
  elif [[ $rc -ne 0 ]]; then
    fail "$name" "gate ran but the wrapper exited $rc, not 0"
  else
    pass "$name" "gate ran"
  fi
}

echo "aura-task-gate.sh — registration"
check_registration

echo "aura-task-gate.sh — the gate always runs"

# The four shapes ROH-157 reproduced. Two of them used to skip the gate entirely;
# the "registered AND delegating" one is what made a stand-aside look reasonable
# in the first place. The config-dir arrangement is the "smarter" reintroduction
# a future stand-aside would most plausibly key on.
scenario "no global hook"                            absent     unregistered
scenario "executable global hook, unregistered"      delegating unregistered
scenario "global hook present but not executable"    nonexec    registered
scenario "zero-byte executable global hook"          empty      unregistered
scenario "global hook registered AND delegating"     delegating registered
scenario "hook via CLAUDE_CONFIG_DIR + XDG dirs"     delegating registered \
  "CLAUDE_CONFIG_DIR=$LAB/home/.claude" "XDG_CONFIG_HOME=$LAB/home"

# The project gate's own state must never produce a silent skip: a lost exec bit
# still runs (the wrapper invokes it through bash), and a missing gate blocks
# loudly instead of passing.
run_gate_nonexec() {
  local repo home rc
  repo="$(make_repo 0 nonexec)"; home="$(make_home absent unregistered)"
  rm -f "$LAB/PROJECT_GATE_RAN"
  ( cd "$repo" && HOME="$home" bash ./.claude/hooks/aura-task-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ -e "$LAB/PROJECT_GATE_RAN" && $rc -eq 0 ]]; then
    pass "project gate without exec bit still runs" "gate ran"
  else
    fail "project gate without exec bit still runs" "ran=$([[ -e $LAB/PROJECT_GATE_RAN ]] && echo yes || echo no), exit $rc"
  fi
}
run_gate_nonexec

run_gate_missing() {
  local repo home out rc
  repo="$(make_repo 0 missing)"; home="$(make_home absent unregistered)"
  out="$( cd "$repo" && HOME="$home" bash ./.claude/hooks/aura-task-gate.sh </dev/null 2>&1 >/dev/null )"; rc=$?
  if [[ $rc -eq 2 ]] && grep -q "missing" <<<"$out"; then
    pass "missing project gate blocks loudly" "exit 2 with reason"
  else
    fail "missing project gate blocks loudly" "expected exit 2 + message, got $rc: $out"
  fi
}
run_gate_missing

echo "aura-task-gate.sh — hook protocol"

# The header calls the stdin drain load-bearing. Assert it: whatever the wrapper
# leaves unread would still be waiting for the next reader.
run_drain() {
  local repo home leftover
  repo="$(make_repo 0)"; home="$(make_home absent unregistered)"
  leftover="$( cd "$repo" && printf 'HOOK_PAYLOAD_JSON\n' |
    { HOME="$home" bash ./.claude/hooks/aura-task-gate.sh >/dev/null 2>&1; cat; } )"
  if [[ -z "$leftover" ]]; then
    pass "stdin payload is drained" "nothing left for the next reader"
  else
    fail "stdin payload is drained" "left behind: $leftover"
  fi
}
run_drain

# A failing project gate has to block, and say why — for the exit code the real
# gate uses (2) and for codes it does not (a crashed or missing-toolchain gate).
run_failing_gate() {
  local code="$1" repo home out rc
  repo="$(make_repo "$code")"; home="$(make_home absent unregistered)"
  out="$( cd "$repo" && HOME="$home" bash ./.claude/hooks/aura-task-gate.sh </dev/null 2>&1 >/dev/null )"; rc=$?
  if [[ $rc -eq 2 ]] && grep -q "stub gate output" <<<"$out"; then
    pass "gate exit $code blocks" "wrapper exit 2, stderr forwarded"
  else
    fail "gate exit $code blocks" "expected exit 2 with output, got $rc: $out"
  fi
}
run_failing_gate 2
run_failing_gate 1
run_failing_gate 127

# Outside a repo there is nothing to gate: fail open rather than block a task.
run_outside_repo() {
  local home rc repo dir="$LAB/notarepo"
  repo="$(make_repo 0)"; mkdir -p "$dir"; home="$(make_home absent unregistered)"
  # The lab's copy, not the live one: the live wrapper would find the real repo if
  # mktemp ever landed inside one, and the real gate runs this script.
  ( cd "$dir" && HOME="$home" bash "$repo/.claude/hooks/aura-task-gate.sh" </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "outside a git repo, fails open" "exit 0"
  else
    fail "outside a git repo, fails open" "expected exit 0, got $rc"
  fi
}
run_outside_repo

# A repo that does NOT carry the wrapper is someone else's checkout: stay out of
# the way even though it has no gate.
run_foreign_repo() {
  local home rc dir="$LAB/foreignrepo" repo
  repo="$(make_repo 0)"; home="$(make_home absent unregistered)"
  rm -rf "$dir"; mkdir -p "$dir"; git -C "$dir" init -q
  ( cd "$dir" && HOME="$home" bash "$repo/.claude/hooks/aura-task-gate.sh" </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "foreign repo without the wrapper, fails open" "exit 0"
  else
    fail "foreign repo without the wrapper, fails open" "expected exit 0, got $rc"
  fi
}
run_foreign_repo

# `set -u` plus an unset HOME used to abort the wrapper before it decided anything,
# and a TaskCompleted hook exiting 1 lets the task through ungated.
run_home_unset() {
  local repo rc
  repo="$(make_repo 0)"; rm -f "$LAB/PROJECT_GATE_RAN"
  ( cd "$repo" && env -u HOME bash ./.claude/hooks/aura-task-gate.sh </dev/null >/dev/null 2>&1 ); rc=$?
  if [[ -e "$LAB/PROJECT_GATE_RAN" && $rc -eq 0 ]]; then
    pass "HOME unset still runs the gate" "exit 0"
  else
    fail "HOME unset still runs the gate" "ran=$([[ -e $LAB/PROJECT_GATE_RAN ]] && echo yes || echo no), exit $rc"
  fi
}
run_home_unset

echo "agent-gate.sh — the survey must not skip published work (ROH-156)"

# These scenarios run the PRODUCTION path — the real wrapper invoking the real
# gate — inside an Aura-shaped lab repo with a real origin. The first round of
# ROH-156 review proved two things these labs now encode:
#   - Asserting on streams the wrapper discards proves nothing. Announcements
#     are asserted on what the wrapper actually lets through.
#   - "Inspected" is observed via PATH stubs recording their own invocation,
#     and "the whole tree was surveyed" via a recording stub at
#     scripts/test-task-gate.sh in the lab: the handoff guard fires only when
#     the survey reached the tracked tree, so a fallback that surveys less than
#     the whole tree cannot fake it.
# The labs run under a synthetic HOME like every other scenario here — the
# ambient ~/.gitconfig (commit.gpgsign, core.hooksPath) must not reach the lab's
# git calls, and these are the only scenarios that run git commit at all.
REAL_GATE="$PWD/.claude/agent-gate.sh"
REAL_WRAPPER="$PWD/.claude/hooks/aura-task-gate.sh"
SURVEY_HOME="${LAB:?}/survey-home"; mkdir -p "$SURVEY_HOME"
sgit() { env HOME="$SURVEY_HOME" git "$@"; }

make_survey_lab() {  # [default_branch]
  local branch="${1:-main}" root="${LAB:?}/survey" w
  rm -rf "$root"; mkdir -p "$root/bin"
  printf '#!/bin/bash\necho "swiftlint $*" >> "%s/INVOKED"; exit 0\n' "$root" >"$root/bin/swiftlint"
  printf '#!/bin/bash\necho "swift $*" >> "%s/INVOKED"; exit 0\n' "$root" >"$root/bin/swift"
  chmod +x "$root/bin/swiftlint" "$root/bin/swift"
  sgit init -q --bare "$root/origin.git"
  sgit clone -q "$root/origin.git" "$root/work" 2>/dev/null
  w="$root/work"
  sgit -C "$w" config user.email lab@example.invalid
  sgit -C "$w" config user.name lab
  sgit -C "$w" checkout -q -b "$branch"
  # Aura-shaped: a Swift source tree, an AuraCore dir for the test cd, inert
  # guard scripts, the REAL wrapper and gate as the lab's own machinery, and a
  # recording stub where the handoff suite would be (it also terminates the
  # gate->suite->gate recursion at depth one inside the lab).
  mkdir -p "$w/Aura/Sources" "$w/scripts" "$w/AuraCore" "$w/.claude/hooks"
  printf 'enum Seed {}\n' >"$w/Aura/Sources/Seed.swift"
  printf 'notes\n' >"$w/NOTES.md"
  : >"$w/AuraCore/.keep"   # tracked, so clones of the lab get the dir too
  local g
  for g in check-explore-rename check-terrain-style check-single-active-definition check-monotonic-instants; do
    printf '#!/bin/bash\nexit 0\n' >"$w/scripts/$g.sh"
  done
  printf '#!/bin/bash\necho "handoff-suite" >> "%s/INVOKED"; exit 0\n' "$root" >"$w/scripts/test-task-gate.sh"
  cp "$REAL_GATE" "$w/.claude/agent-gate.sh"
  cp "$REAL_WRAPPER" "$w/.claude/hooks/aura-task-gate.sh"
  sgit -C "$w" add -A
  sgit -C "$w" commit -qm baseline
  sgit -C "$w" push -q origin "$branch"
  printf '%s\n' "$root"
}

run_survey() {  # <root> [workdir]; sets SURVEY_RC, SURVEY_OUT, SURVEY_INVOKED
  local root="$1" w="${2:-$1/work}"
  rm -f "$root/INVOKED"
  SURVEY_OUT="$( cd "$w" && env HOME="$SURVEY_HOME" PATH="$root/bin:$PATH" \
    bash ./.claude/hooks/aura-task-gate.sh </dev/null 2>&1 )"; SURVEY_RC=$?
  SURVEY_INVOKED="$(cat "$root/INVOKED" 2>/dev/null || true)"
}

inspected()  { grep -q '^swiftlint' <<<"$SURVEY_INVOKED" && grep -q '^swift test' <<<"$SURVEY_INVOKED"; }
whole_tree() { grep -q '^handoff-suite' <<<"$SURVEY_INVOKED"; }
survey_diag() { printf 'exit %s, invoked=[%s], out=[%s]' "$SURVEY_RC" "${SURVEY_INVOKED//$'\n'/, }" "${SURVEY_OUT//$'\n'/ | }"; }

# ROH-156 case 1: work committed and pushed on main, tree clean, HEAD ==
# origin/main. The change survey is empty at exactly the moment the code left
# the machine unverified — the gate must widen to the whole tree, and say so
# through the wrapper, where an agent can actually encounter it.
survey_published_clean() {
  local root; root="$(make_survey_lab)"
  printf 'struct A {}\n' >"$root/work/Aura/Sources/A.swift"
  sgit -C "$root/work" add -A && sgit -C "$root/work" commit -qm work && sgit -C "$root/work" push -q origin main
  run_survey "$root"
  if [[ $SURVEY_RC -eq 0 ]] && inspected && whole_tree && grep -q 'published tip' <<<"$SURVEY_OUT"; then
    pass "published tip, clean tree: inspects whole tree" "lint+tests+handoff ran, announced"
  else
    fail "published tip, clean tree: inspects whole tree" "$(survey_diag)"
  fi
}
survey_published_clean

# The self-disarm trap: at the published tip, one line of incidental non-Swift
# dirt (the shape swift test itself leaves in AuraCore/Package.resolved) must
# not suppress the fallback. Emptiness is not the trigger; being at the
# published tip is.
survey_published_with_dirt() {
  local root; root="$(make_survey_lab)"
  printf 'struct A {}\n' >"$root/work/Aura/Sources/A.swift"
  sgit -C "$root/work" add -A && sgit -C "$root/work" commit -qm work && sgit -C "$root/work" push -q origin main
  printf 'stray\n' >>"$root/work/NOTES.md"
  run_survey "$root"
  if [[ $SURVEY_RC -eq 0 ]] && inspected && whole_tree; then
    pass "published tip + non-Swift dirt still inspects" "fallback not suppressed by dirt"
  else
    fail "published tip + non-Swift dirt still inspects" "$(survey_diag)"
  fi
}
survey_published_with_dirt

# A branch name is not a discriminator: a feature branch sitting at the
# published tip is byte-identical in git whether it got there by a reviewed
# merge or a direct `git push HEAD:main`. Both inspect — that is the deliberate
# cost of not being gameable by a rename.
survey_published_feature_branch() {
  local root; root="$(make_survey_lab)"
  printf 'struct A {}\n' >"$root/work/Aura/Sources/A.swift"
  sgit -C "$root/work" add -A && sgit -C "$root/work" commit -qm work && sgit -C "$root/work" push -q origin main
  sgit -C "$root/work" checkout -q -b claude/at-tip
  run_survey "$root"
  if [[ $SURVEY_RC -eq 0 ]] && inspected && whole_tree; then
    pass "feature branch at published tip inspects" "SHA match, not branch name"
  else
    fail "feature branch at published tip inspects" "$(survey_diag)"
  fi
}
survey_published_feature_branch

# Detached HEAD at the published tip (bisect, rebase mid-flight) is the same
# published state and must inspect too.
survey_published_detached() {
  local root; root="$(make_survey_lab)"
  sgit -C "$root/work" checkout -q --detach
  run_survey "$root"
  if [[ $SURVEY_RC -eq 0 ]] && inspected && whole_tree; then
    pass "detached HEAD at published tip inspects" "SHA match survives detachment"
  else
    fail "detached HEAD at published tip inspects" "$(survey_diag)"
  fi
}
survey_published_detached

# master-default repos resolve their baseline too.
survey_published_master() {
  local root; root="$(make_survey_lab master)"
  run_survey "$root"
  if [[ $SURVEY_RC -eq 0 ]] && inspected && whole_tree && grep -q 'published tip' <<<"$SURVEY_OUT"; then
    pass "master-default repo inspects at published tip" "origin/master resolved"
  else
    fail "master-default repo inspects at published tip" "$(survey_diag)"
  fi
}
survey_published_master

# The genuinely benign shape: HEAD strictly BEHIND the published tip (a feature
# tip after someone else's merge advanced main). Nothing new exists to check,
# so skipping stays correct — but the skip must be visible through the wrapper,
# because a silent no-op is indistinguishable from inspected-and-passed.
survey_behind_tip_skips_visibly() {
  local root; root="$(make_survey_lab)"
  printf 'enum Seed2 {}\n' >"$root/work/Aura/Sources/Seed2.swift"
  sgit -C "$root/work" add -A && sgit -C "$root/work" commit -qm advance && sgit -C "$root/work" push -q origin main
  sgit -C "$root/work" checkout -q -b claude/behind HEAD~1
  run_survey "$root"
  if [[ $SURVEY_RC -eq 0 && -z "$SURVEY_INVOKED" ]] && grep -q 'nothing to inspect' <<<"$SURVEY_OUT"; then
    pass "tip strictly behind published main skips visibly" "skip announced through wrapper"
  else
    fail "tip strictly behind published main skips visibly" "$(survey_diag)"
  fi
}
survey_behind_tip_skips_visibly

# Regression pin on the ordinary path: unpushed work on a feature branch keeps
# inspecting exactly as before — no whole-tree widening, no skip message.
survey_branch_unpushed() {
  local root; root="$(make_survey_lab)"
  sgit -C "$root/work" checkout -q -b claude/wip
  printf 'struct B {}\n' >"$root/work/Aura/Sources/B.swift"
  sgit -C "$root/work" add -A && sgit -C "$root/work" commit -qm wip
  run_survey "$root"
  if [[ $SURVEY_RC -eq 0 ]] && inspected && ! whole_tree \
      && ! grep -q 'whole tracked tree\|nothing to inspect' <<<"$SURVEY_OUT"; then
    pass "unpushed feature work inspects as before" "lint+tests ran, survey not widened"
  else
    fail "unpushed feature work inspects as before" "$(survey_diag)"
  fi
}
survey_branch_unpushed

# A checkout where no baseline resolves at all (single-branch clone of a
# feature branch) cannot certify "nothing new to verify", so it must fail safe
# into the whole-tree survey rather than skip.
survey_no_baseline() {
  local root w; root="$(make_survey_lab)"
  sgit -C "$root/work" checkout -q -b feature
  printf 'struct C {}\n' >"$root/work/Aura/Sources/C.swift"
  sgit -C "$root/work" add -A && sgit -C "$root/work" commit -qm feature-work
  sgit -C "$root/work" push -q origin feature
  w="$root/single"
  sgit clone -q --single-branch -b feature "$root/origin.git" "$w" 2>/dev/null
  run_survey "$root" "$w"
  if [[ $SURVEY_RC -eq 0 ]] && inspected && whole_tree; then
    pass "unresolvable baseline fails safe into whole tree" "inspected despite no origin/main"
  else
    fail "unresolvable baseline fails safe into whole tree" "$(survey_diag)"
  fi
}
survey_no_baseline

echo
if [[ $failures -eq 0 ]]; then echo "PASS"; exit 0; fi
echo "FAIL: $failures scenario(s)"
echo
echo "Failures in the 'gate always runs' / 'hook protocol' sections: the wrapper at"
echo ".claude/hooks/aura-task-gate.sh must run .claude/agent-gate.sh unconditionally"
echo "inside this repo — no stand-aside, no silent exit. Someone likely reintroduced"
echo "one, or broke the TaskCompleted registration in .claude/settings.json. See"
echo "ROH-157 and the wrapper's header."
echo
echo "Failures in the 'survey must not skip published work' section: the gate's"
echo "change survey or its published-tip fallback regressed, or the wrapper stopped"
echo "forwarding the gate's announcements on success. See ROH-156 and the survey"
echo "comments in .claude/agent-gate.sh."
exit 1
