#!/usr/bin/env bash
#
# TaskCompleted entry point declared in .claude/settings.json.
#
# It exists so that cloning the repo is enough to get Aura's quality gate, with no
# user-scope install step. It runs .claude/agent-gate.sh in every state except two:
# cwd is not inside a git repo at all, or the repo it is inside does not carry this
# wrapper (a foreign checkout this script was invoked in by hand). Inside an
# Aura-shaped repo there is no silent exit: the gate runs, or the task is blocked
# with a reason. The gate is invoked through `bash` so a lost executable bit cannot
# turn it off, and a missing gate file blocks loudly instead of passing silently.
#
# It used to stand aside when a global hook at ~/.claude/hooks/agent-gate.sh looked
# like it would run the gate instead. Its entire test was `[[ -x that-file ]]`, so a
# zero-byte executable file at that path turned Aura's gate off completely, with
# nothing changed in the repo and no message anywhere. That was ROH-157. Two
# attempts to make the detection trustworthy both failed adversarial review, and the
# reason generalises: any such check reasons about files this repo does not own, and
# every version had a realistic spelling that stood aside while nothing ran. So
# there is no detection here. Running twice wastes CPU; not running ships unlinted,
# untested code. Those are not comparable.
#
# If you carry both hooks and want the single run back, the lever is the global
# one: it is user-scope and yours to edit. The safe edit is a stand-aside in the
# GLOBAL hook keyed on this repo carrying the project wrapper — guessing wrong
# there costs a duplicate run, never a silent skip, because the checked-in project
# hook still fires. See docs/COLLABORATOR-TASKS.md. The project hook is checked in
# so a fresh clone keeps its gate; do not remove it for this.
#
# scripts/test-task-gate.sh pins this contract and CI runs it; the gate itself
# re-runs it whenever this machinery changes.
#
# The stdin drain matters: the hook payload has to be consumed or the writer can
# block on a full pipe.

set -uo pipefail

cat >/dev/null 2>&1 || true

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
gate="$repo/.claude/agent-gate.sh"

# A repo that carries this wrapper is an Aura-shaped repo: its gate is a tracked
# file, so its absence means a broken tree, not a repo with nothing to gate.
if [[ ! -f "$gate" ]]; then
  [[ -f "$repo/.claude/hooks/aura-task-gate.sh" ]] || exit 0
  {
    echo "Task blocked: $gate is missing, so Aura's quality gate cannot run."
    echo "Restore it (git checkout -- .claude/agent-gate.sh) and complete the task again."
  } >&2
  exit 2
fi

out="$(bash "$gate" </dev/null 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && exit 0
printf '%s\n' "$out" >&2
exit 2
