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
# The registration in .claude/settings.json invokes this file as
# `bash "${CLAUDE_PROJECT_DIR:-.}"/.claude/hooks/aura-task-gate.sh || exit 2`
# (ROH-187). Both halves are deliberate and this comment is their
# documentation, since JSON carries none:
#
#   - The guarded expansion: the hooks reference lists where
#     CLAUDE_PROJECT_DIR is set but does not guarantee it for every session
#     type, and with the bare `"$CLAUDE_PROJECT_DIR"` form an unset or empty
#     variable becomes `bash /.claude/hooks/...` -> exit 127 -> a NON-blocking
#     hook error -> the task completes ungated with no message anywhere — the
#     ROH-157 shape through the registration itself. `.` falls back to the
#     hook's working directory.
#   - The `|| exit 2` tail is the fail-closed backstop for every remaining
#     launch failure (cwd not the project root with the variable unset, a
#     deleted wrapper, an unreadable file): anything that stops this wrapper
#     from rendering its own verdict becomes a BLOCK with bash's error as the
#     reason, never a silent pass. The wrapper's benign exit-0 paths (outside
#     a repo, foreign checkout) are unaffected.
#
# Authority is split on purpose: CLAUDE_PROJECT_DIR locates this FILE; the
# repo under inspection comes from cwd (git rev-parse below). A worktree
# session runs the parent checkout's registration with cwd inside the
# worktree, and it is the worktree — the tree the task actually changed — that
# must be gated. Deriving the repo from the variable would gate the wrong tree
# in exactly that flow.
#
# scripts/test-task-gate.sh executes the registered command string with the
# variable set, unset, and empty, from the repo root and from a subdirectory —
# parsing alone cannot see a broken expansion.
#
# scripts/test-task-gate.sh pins this contract and CI runs it; the gate itself
# re-runs it whenever this machinery changes.
#
# The stdin drain matters: the hook payload has to be consumed or the writer can
# block on a full pipe. It is an unbounded read and sits OUTSIDE the gate's
# internal deadline — a harness that never closes the write end would hold it
# to the hook timeout. Accepted: the harness closes stdin after the payload,
# and a bounded drain would trade a theoretical hang for a real risk of
# truncating the payload mid-write.

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
if [[ $rc -eq 0 ]]; then
  # Forward what the gate said even on success (ROH-156): the gate announces
  # when it skips or widens its survey, and output swallowed here is output
  # that never existed anywhere. Per the hooks reference, TaskCompleted stdout
  # on exit 0 reaches only the debug log — nobody sees it live, but the
  # decision becomes reconstructable, which a discarded string never is. The
  # agent-visible channel stays exit 2, which the failure path uses.
  [[ -n "$out" ]] && printf '%s\n' "$out"
  exit 0
fi
printf '%s\n' "$out" >&2
exit 2
