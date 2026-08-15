#!/usr/bin/env bash
#
# TaskCompleted entry point declared in .claude/settings.json.
#
# It exists so that cloning the repo is enough to get Aura's quality gate, with no
# user-scope install step. All it does is decide who runs the real gate:
#
#   - If a global hook is registered as a TaskCompleted hook, resolves to the file
#     at <config>/hooks/agent-gate.sh, and that file delegates to this repo's
#     .claude/agent-gate.sh, do nothing. It is about to run the same gate.
#   - Otherwise run .claude/agent-gate.sh directly.
#
# The decision is deliberately asymmetric (ROH-157). Standing aside when nothing
# else runs the gate is silent and total: no lint, no tests, no guard scripts, and
# no message anywhere. Running when something else also ran is cheap, because
# .claude/agent-gate.sh dedupes concurrent runs of the same tree. So this stands
# aside only on positive evidence, and treats every uncertainty as a reason to run.
#
# What this is NOT: proof. It reads files belonging to Claude Code, not to this
# repo, and a global hook that names the project gate inside a branch it never
# takes will still pass. That residual weakness is affordable precisely because
# the gate's own dedupe makes the "ran twice" outcome cheap — this check is an
# optimisation, not the thing correctness rests on.
#
# The stdin drain matters in both branches: the hook payload has to be consumed or
# the writer can block on a full pipe.

set -uo pipefail

cat >/dev/null 2>&1 || true

# Unset HOME would abort under `set -u` and complete the task ungated, so it is
# treated as "cannot confirm" like any other unknown.
config_dir="${CLAUDE_CONFIG_DIR:-${HOME:-/nonexistent}/.claude}"
global_hook="$config_dir/hooks/agent-gate.sh"

# True only when a global TaskCompleted hook will demonstrably run this repo's gate.
global_hook_covers_us() {
  # 1. It has to exist and be runnable. This was previously the entire test, and a
  #    zero-byte executable satisfied it.
  [[ -x "$global_hook" ]] || return 1

  # 2. Its CODE has to name the project gate. Comments are stripped first: the
  #    stock global hook documents the project-override contract in its header, so
  #    a copy that keeps the prose and drops the delegation would otherwise pass.
  sed 's/#.*//' "$global_hook" 2>/dev/null | grep -q '\.claude/agent-gate\.sh' || return 1

  # 3. That exact file has to be the one wired to TaskCompleted. Matching on the
  #    substring "agent-gate.sh" is not enough: a stale copy at this path plus a
  #    settings entry pointing somewhere else satisfies it while nothing runs,
  #    which is ROH-157 through a second door. Compare resolved paths instead, and
  #    read `args` as well as `command` so the documented exec form is understood.
  #
  #    Only <config>/settings.json is consulted. Hooks can also arrive from managed
  #    settings, plugins, and elsewhere; every one of those we cannot see makes us
  #    run rather than stand aside, which is the safe direction.
  python3 - "$global_hook" "$config_dir/settings.json" <<'PY' 2>/dev/null
import json, os, shlex, sys

target, settings = os.path.realpath(sys.argv[1]), sys.argv[2]
try:
    with open(settings) as fh:
        cfg = json.load(fh)
except Exception:
    sys.exit(1)

def tokens(hook):
    out = []
    command = hook.get("command")
    if isinstance(command, str):
        try:
            out += shlex.split(command)
        except ValueError:
            out += command.split()
    args = hook.get("args")
    if isinstance(args, list):
        out += [str(a) for a in args]
    return out

groups = cfg.get("hooks", {}).get("TaskCompleted") or []
for group in groups:
    for hook in group.get("hooks") or []:
        for token in tokens(hook):
            path = os.path.expanduser(os.path.expandvars(token))
            try:
                if os.path.realpath(path) == target:
                    sys.exit(0)
            except (OSError, ValueError):
                continue
sys.exit(1)
PY
}

if global_hook_covers_us; then
  # This line is what the test harness observes to tell "stood aside" apart from
  # "died before deciding". Both leave the gate unrun; only one is correct.
  [[ -n "${AURA_GATE_VERBOSE:-}" ]] &&
    echo "aura-task-gate: standing aside; $global_hook is registered and delegates" >&2
  exit 0
fi

[[ -n "${AURA_GATE_VERBOSE:-}" ]] &&
  echo "aura-task-gate: running the project gate; no global hook confirmed" >&2

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
gate="$repo/.claude/agent-gate.sh"
[[ -x "$gate" ]] || exit 0

out="$("$gate" </dev/null 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && exit 0
printf '%s\n' "$out" >&2
exit 2
