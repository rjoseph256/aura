# Aura development board

Ongoing work is tracked on a GitHub Projects (v2) board, backed by issues on
`rjoseph256/aura`. [docs/ROADMAP.md](ROADMAP.md) stays the narrative record of what
shipped and why; the board is the live task tracker on top of it.

- **Board:** https://github.com/users/rjoseph256/projects/1 ("Aura Development", project number `1`)
- **Owner (login):** `rjoseph256` · **Repo:** `rjoseph256/aura`
- **Project node id:** `PVT_kwHOBx_p3s4BcSZv`

## Roles

- **Rohun is PO/PM.** He reprioritizes, adds or cuts features, drags cards, and makes
  the release calls in the Projects UI.
- **Claude drives the board.** Creates/updates/moves/closes issues as work lands, keeps
  fields honest, and never marks an epic Done until it actually ships.

## Structure

- **Status** (board columns): Backlog → Ready → In Progress → In Review → Blocked → Done
- **Type:** Epic · Feature · Bug · Chore · Verification
- **Priority:** P0 · P1 · P2 · P3
- **Epic:** Device Verification · Group Rides Tail · System Surfaces · Summary & Map Polish ·
  Platform Bets · Product & Release · Shipped
- **Wave:** Wave 0 · Wave 1 · Wave 2 · Wave 3 · Wave 4+ · Backlog

Epics are tracking issues (`Type=Epic`, labeled `epic`). Their tasks are GitHub
**sub-issues** of the epic, so the parent shows real progress. Shipped waves (0–3) plus
iCloud sync, saved places, and the share card are closed epics with `Epic=Shipped`.

## Field / option ids (for the API)

```
Status   PVTSSF_lAHOBx_p3s4BcSZvzhW8Vh4   Backlog=b848da65 Ready=db91004e InProgress=9237ea2d InReview=7fe7dc06 Blocked=ea8a50ff Done=44cb9c34
Type     PVTSSF_lAHOBx_p3s4BcSZvzhW8VlU   Epic=5481255a Feature=135c3db0 Bug=34955dac Chore=d4862dd6 Verification=d65f5ac4
Priority PVTSSF_lAHOBx_p3s4BcSZvzhW8Vlc   P0=6dda0800 P1=8ad35a5d P2=3855ad09 P3=5e3798b3
Epic     PVTSSF_lAHOBx_p3s4BcSZvzhW8Vlk   DeviceVerification=0add18ae GroupRidesTail=040c23bc SystemSurfaces=c97dfe66 Summary&MapPolish=f4f36ea3 PlatformBets=6b79cdfb Product&Release=02e9420b Shipped=908d2167
Wave     PVTSSF_lAHOBx_p3s4BcSZvzhW8Vls   Wave0=16fc6277 Wave1=3e212213 Wave2=5616bbe5 Wave3=f6fe74c7 Wave4+=259648d6 Backlog=87da5b17
```

Re-derive any time: `gh project field-list 1 --owner rjoseph256 --format json`.

## How Claude drives it (recipes)

Prereq: `gh` authed with the `project` scope (`gh auth refresh -h github.com -s project`).

```sh
# Create an issue and note its number + node_id
gh api --method POST /repos/rjoseph256/aura/issues -f title="…" -f body="…" -f 'labels[]=group-rides'

# Add an existing issue (by node id) to the board -> returns the item id
gh api graphql -f query='mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}' \
  -F p=PVT_kwHOBx_p3s4BcSZv -F c=<ISSUE_NODE_ID>

# Set a single-select field on a board item (Status/Type/Priority/Epic/Wave)
gh api graphql -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' \
  -F p=PVT_kwHOBx_p3s4BcSZv -F i=<ITEM_ID> -F f=<FIELD_ID> -F o=<OPTION_ID>

# Make an issue a sub-issue of an epic (both by node id)
gh api graphql -H "GraphQL-Features: sub_issues" \
  -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){subIssue{number}}}' \
  -F p=<EPIC_NODE_ID> -F c=<CHILD_NODE_ID>

# Move a card: set Status to In Progress / Done, etc. (same as set-field above)
# Close a finished issue
gh api --method PATCH /repos/rjoseph256/aura/issues/<N> -f state=closed -f state_reason=completed

# Read the board
gh project item-list 1 --owner rjoseph256 --limit 100 --format json
```

Common flow when Claude starts a task: move its issue to **In Progress**; when the PR is
up, **In Review**; when merged/verified, **Done** and close it. Device-dependent items
that can't be finished by tooling sit in **Blocked** with a note on what's needed.
