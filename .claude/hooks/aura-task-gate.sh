#!/usr/bin/env bash
#
# TaskCompleted entry point declared in .claude/settings.json.
#
# It exists so that cloning the repo is enough to get Aura's quality gate, with no
# user-scope install step. All it does is decide who runs the real gate:
#
#   - If a global hook is installed AND registered AND delegates to this repo's
#     .claude/agent-gate.sh, do nothing. It is about to run the same gate, and
#     running it here too would gate every task twice at full cost.
#   - Otherwise run .claude/agent-gate.sh directly.
#
# The decision is deliberately asymmetric (ROH-157). Standing aside when nothing
# else runs the gate is silent and total: no lint, no tests, no guard scripts, and
# no message anywhere. Running when something else also ran costs time. So this
# stands aside only on positive evidence, and treats every uncertainty — an
# unreadable settings file, no python3 to parse it, a hook that does its own thing
# — as a reason to run.
#
# The stdin drain matters in both branches: the hook payload has to be consumed or
# the writer can block on a full pipe.

set -uo pipefail

cat >/dev/null 2>&1 || true

global_hook="$HOME/.claude/hooks/agent-gate.sh"

# True only when a global TaskCompleted hook will demonstrably run this repo's gate.
global_hook_covers_us() {
  # 1. It has to exist and be runnable. This was previously the entire test, and a
  #    zero-byte executable satisfied it.
  [[ -x "$global_hook" ]] || return 1

  # 2. It has to delegate to the project gate. A global gate that runs its own
  #    built-in checks is not a substitute: this repo needs `swift test
  #    --no-parallel` (a bare `swift test` races the SwiftData suites, ROH-65) plus
  #    four guard scripts a generic lint-and-test pass knows nothing about. Reading
  #    someone else's script is inference, but "does it name our gate" is a far
  #    narrower question than "does this file exist".
  grep -q '\.claude/agent-gate\.sh' "$global_hook" 2>/dev/null || return 1

  # 3. It has to be wired to TaskCompleted. A file at that path that no settings
  #    file references never runs, which was ROH-157 itself. Parsed rather than
  #    grepped, so a hook registered under some other event cannot pass for one
  #    registered under this one.
  command -v python3 >/dev/null 2>&1 || return 1
  local settings
  for settings in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
    [[ -f "$settings" ]] || continue
    python3 -c '
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for group in cfg.get("hooks", {}).get("TaskCompleted") or []:
    for hook in group.get("hooks") or []:
        if "agent-gate.sh" in str(hook.get("command", "")):
            sys.exit(0)
sys.exit(1)
' "$settings" 2>/dev/null && return 0
  done
  return 1
}

if global_hook_covers_us; then
  # Silent by default: this is the common, correct path on a machine with the
  # two-tier setup, and a line here would print on every completed task.
  [[ -n "${AURA_GATE_VERBOSE:-}" ]] &&
    echo "aura-task-gate: standing aside; $global_hook is registered and delegates" >&2
  exit 0
fi

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
gate="$repo/.claude/agent-gate.sh"
[[ -x "$gate" ]] || exit 0

out="$("$gate" </dev/null 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && exit 0
printf '%s\n' "$out" >&2
exit 2
