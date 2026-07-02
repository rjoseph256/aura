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
