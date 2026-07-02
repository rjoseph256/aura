# Aura — project instructions

## Development flow: use the task board (required)

Aura development runs through the GitHub Projects board — **project 1 on
`rjoseph256/aura`** (https://github.com/users/rjoseph256/projects/1). Using and
updating the board is part of the official development flow, not optional
bookkeeping.

- Every dev task has a card on the board **before** implementation starts — create
  one if it doesn't exist.
- Move the card's **Status** as the work progresses: **In Progress** when you start →
  **In Review** when a PR is open → **Done** (and close the issue) when it's merged and
  verified.
- Park anything blocked on hardware, an external service, or a user action in
  **Blocked**, with a note on what's needed.
- Keep the **Type**, **Priority**, and **Epic** fields honest as things change.
- Rohun is PO/PM (prioritizes, adds or cuts work, drags cards); Claude drives the
  issues and keeps status truthful.

Board mechanics — the project/field/option ids and the `gh` + GraphQL recipes for
creating, filing, moving, and closing cards — live in [docs/BOARD.md](docs/BOARD.md).
The narrative record of what shipped and what's next is [docs/ROADMAP.md](docs/ROADMAP.md).
