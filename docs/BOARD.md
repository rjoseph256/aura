# Aura development board

Ongoing work is tracked in **Linear**. [docs/ROADMAP.md](ROADMAP.md) stays the narrative
record of what shipped and why; Linear is the live task tracker on top of it.

- **Workspace:** https://linear.app/rohun
- **Team:** Rohun — key `ROH` (id `f2b5e5de-59a4-4f9b-ad9b-8f60d5565970`)
- Reached via the **Linear MCP connector** (must be authorized in the session — claude.ai
  connector settings, or `/mcp` in an interactive terminal).

The old GitHub Projects board was decommissioned on 2026-07-02 (its 44 issues were closed
as history on `rjoseph256/aura`; the board was deleted).

## Roles

- **Rohun is PO/PM.** Prioritizes, adds or cuts work, and moves issues in Linear.
- **Claude drives the board.** Creates/updates/moves issues as work lands, keeps status
  and labels honest, and never marks an issue Done until it actually ships.

## Structure

- **Projects = epics:** Summary & Map Polish, Device Verification, Group Rides Tail,
  System Surfaces, Platform Bets, Product & Release, and a completed **Shipped** project
  (historical waves).
- **Workflow states:** Backlog → Todo → In Progress → In Review → Done (plus Canceled).
- **Priority:** Urgent · High · Medium · Low · No priority.
- **Labels (groups):** `Type` (Feature · Bug · Chore · Verification) and
  `Wave` (Wave 0 … Wave 4+).

Issues live inside their epic's Project. Sub-work that isn't part of an epic (e.g. the
worktree-sweep chore) is a project-less issue with the right Type label.

## How Claude drives it (Linear MCP)

Tools are `mcp__<linear-server>__*` (fetch schemas with ToolSearch first). Key ones:

```
list_teams / list_projects / list_issues / list_issue_statuses / list_issue_labels
save_issue   — create or update an issue (id to update; title+team to create).
               Fields: project, state, priority (0=None..4=Low), labels, assignee, description.
save_project — create or update a project (epic). Fields: state, priority, color, summary.
create_issue_label — new label (isGroup for a group; parent to nest).
```

Common flow when Claude starts a task: move its issue to **In Progress**; when the PR is
up, **In Review**; when merged/verified, **Done**. New work → create the issue in the
right Project first. Priority maps from the old scheme as Urgent/High/Medium/Low.
