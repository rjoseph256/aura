#!/usr/bin/env bash
#
# TaskCompleted entry point declared in .claude/settings.json.
#
# It exists so that cloning the repo is enough to get Aura's quality gate, with no
# user-scope install step. It runs .claude/agent-gate.sh. Always, unconditionally.
#
# It used to try not to. A global hook at ~/.claude/hooks/agent-gate.sh runs
# <repo>/.claude/agent-gate.sh as a project override, so on a machine carrying both
# each task was gated twice, and this script tried to detect that and stand aside.
# Its entire test was `[[ -x "$HOME/.claude/hooks/agent-gate.sh" ]]`, so a
# zero-byte executable file at that path turned Aura's gate off completely, with
# nothing changed in the repo and no message anywhere. That was ROH-157.
#
# Two attempts to make the detection trustworthy both failed adversarial review,
# and the reason generalises: any such check has to reason about files this repo
# does not own, and every version had a realistic spelling that stood aside while
# nothing ran — a registration naming a different path, a hook that names the gate
# only in a comment, a delegation sitting behind a condition. Caching verdicts so
# that running twice would be cheap turned out worse still: it could replay a stale
# pass and let a task through ungated, which is a worse failure than the one it was
# meant to fix.
#
# So there is no detection. Running twice wastes CPU; not running ships unlinted,
# untested code. Those are not comparable, and this errs entirely toward the cheap
# one. scripts/test-task-gate.sh pins that: no arrangement of the global hook can
# make this stand aside.
#
# If you carry both hooks and want the single run back, the lever is the global
# one: it is user-scope and yours to edit or unregister. The project hook is
# checked in so that a fresh clone keeps its gate; do not remove it for this.
#
# The stdin drain matters: the hook payload has to be consumed or the writer can
# block on a full pipe.

set -uo pipefail

cat >/dev/null 2>&1 || true

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
gate="$repo/.claude/agent-gate.sh"
[[ -x "$gate" ]] || exit 0

out="$("$gate" </dev/null 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && exit 0
printf '%s\n' "$out" >&2
exit 2
