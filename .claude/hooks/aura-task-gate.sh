#!/usr/bin/env bash
#
# TaskCompleted entry point declared in .claude/settings.json.
#
# It exists so that cloning the repo is enough to get Aura's quality gate, with no
# user-scope install step. All it does is decide who runs the real gate:
#
#   - If a global hook is installed at ~/.claude/hooks/agent-gate.sh, do nothing.
#     That hook already executes <repo>/.claude/agent-gate.sh as a project override,
#     so running it here too would gate every task twice, at full cost.
#   - Otherwise run .claude/agent-gate.sh directly.
#
# The stdin drain matters in both branches: the hook payload has to be consumed or
# the writer can block on a full pipe.

set -uo pipefail

cat >/dev/null 2>&1 || true

[[ -x "$HOME/.claude/hooks/agent-gate.sh" ]] && exit 0

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
gate="$repo/.claude/agent-gate.sh"
[[ -x "$gate" ]] || exit 0

out="$("$gate" </dev/null 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && exit 0
printf '%s\n' "$out" >&2
exit 2
