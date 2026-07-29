# Aura — project instructions

## Development flow: use the Linear board (required)

Aura development runs through **Linear** — workspace **`linear.app/rohun`**, team
**Rohun** (`ROH`). Using and updating the board is part of the official development
flow, not optional bookkeeping.

- Every dev task is a Linear **issue** under the right **Project** (epic) **before**
  implementation starts — create one if it doesn't exist.
- Move the issue's **status** as the work progresses: **Todo** (ready) → **In Progress**
  when you start → **In Review** when a PR is open → **Done** when it's merged and verified.
- Leave anything blocked on hardware, an external service, or a user action in
  **Backlog** (or **Canceled** if dropped), with a note on what's needed.
- Keep **priority** (Urgent/High/Medium/Low) and the `Type`/`Wave` **labels** honest.
- Rohun is PO/PM (prioritizes, adds or cuts work, moves issues); Claude drives the
  issues and keeps status truthful.

**Projects (epics):** Summary & Map Polish, Device Verification, Group Rides Tail,
System Surfaces, Platform Bets, Product & Release, and a completed **Shipped** project
for historical waves.

Board mechanics — the team/label/state vocabulary and how to drive Linear via its MCP
connector — live in [docs/BOARD.md](docs/BOARD.md). The narrative record of what shipped
and what's next is [docs/ROADMAP.md](docs/ROADMAP.md).

> Linear is reached through its MCP connector, which must be authorized in the session
> (claude.ai connector settings, or `/mcp` in an interactive terminal). The old GitHub
> Projects board was decommissioned on 2026-07-02.

## How work gets done here (required)

These override default agent behavior on purpose. They exist because each one has caught
something that the default flow shipped. They apply to every session in this repo, on
anyone's machine.

**Major feature work runs the full pipeline, including the review gates.** Any new
user-facing feature, subsystem, or non-trivial redesign, meaning anything that warrants a
design decision before code:

1. `superpowers:brainstorming` to settle intent, then get explicit approval on the design.
2. **Adversarial spec review.** Dispatch 2 to 3 independent reviewer subagents with
   *different* lenses (`review-skeptic`, `review-product`, `review-architecture`), each told
   to refute the spec rather than agree with it. Reconcile before planning.
3. `superpowers:writing-plans` for a bite-sized TDD plan.
4. **Adversarial plan review.** 2 or more independent reviewers, refuting stance, against
   the plan. Fix before executing.
5. `superpowers:subagent-driven-development`, fresh implementer plus reviewer per task.
6. One whole-branch review on the most capable model before finishing.

Scale reviewer count to risk, 2 for something contained and 3 or more for anything
load-bearing or hard to reverse, but never drop to zero on major work. The gates are the
part that gets skipped under time pressure and the part that has repeatedly caught defects
green tests and single-pass review missed. ROH-7 was killed at a spec review before any code
was written; the group-rides SP3 whole-branch review caught three production-dead criticals
that unit tests passed.

Reviewers must be independent (fresh subagents, no shared context) and given distinct lenses
so they do not converge on one blind spot. Dispatch agent types that have no Agent tool, so
grandchild subagents are structurally impossible rather than merely discouraged.

Not for one-line fixes, mechanical edits, or pure debugging. Those go straight to the
relevant skill: `superpowers:systematic-debugging` for a bug,
`superpowers:test-driven-development` for a contained change.

**Apple-platform work consults the matching skill before writing code.** Swift, SwiftUI,
UIKit, or any Apple framework: route to the `all-ios-skills` skill for that area
(`swift-concurrency`, `swiftdata`, `activitykit`, `widgetkit`, `healthkit`,
`swiftui-navigation`, and so on) rather than writing from training-data recall. Apple API
shape and concurrency rules move faster than any model's memory of them. Delegate builds and
tests to the `apple-platform-build-tools` builder subagent, which absorbs xcodebuild output
instead of filling the session with it.

**UI work is verified on a device, not asserted.** A clean build does not prove a feature
does anything. The Terrain-RGB elevation bug compiled fine and returned flat everywhere. Run
the app and look, and prefer a real device over the simulator for anything involving GPS,
haptics, background recording, widgets, Live Activities, or a locked screen.

**Prose deliverables run through `humanizer`.** Specs, docs, PR bodies, issue descriptions,
anything a person reads. Not commit messages, code comments, or short status replies.

Visual design of native SwiftUI surfaces follows the iOS skills and direct design judgment.
The web design skills (`impeccable` and friends) are not needed here and are not installed
for this repo.

## Session setup

`.claude/settings.json` is checked in and declares the plugins this repo needs, so a clone
gets the right toolset without a manual install. It also declares a `TaskCompleted` hook that
runs `.claude/agent-gate.sh`, which lints and runs the package suite before an agent may call
a task complete. The gate does not build the app or run pgTAP, so CI can still fail after it
passes.

Machine setup is [docs/COLLABORATOR-SETUP.md](docs/COLLABORATOR-SETUP.md). A second
developer's issue lane is [docs/COLLABORATOR-TASKS.md](docs/COLLABORATOR-TASKS.md).
