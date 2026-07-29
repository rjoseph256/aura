# A second developer's lane

[COLLABORATOR-SETUP.md](COLLABORATOR-SETUP.md) gets a second Mac building and running Aura.
This file answers the next question: which board work that person can actually finish alone,
how their Claude Code should be set up so their sessions run the same process as the owner's,
and how they pick up work each morning without waiting to be handed a task.

Written for Andrew. Board state as of 2026-07-28.

## What makes an issue independent here

Three things gate most of the ROH board, and all three trace back to the owner rather than to
the code:

1. **Two phones and two Apple IDs.** Every group-ride and iCloud verification item needs the
   owner's device riding alongside a second one. One person cannot close them.
2. **Supabase and the Apple account.** Migrations, edge functions, the CloudKit dashboard, and
   any capability that has to be enabled on the app id all live under the owner's credentials.
   A collaborator can write the SQL but cannot apply it.
3. **Two epics the owner is actively driving.** Pause and Segmented Rides (ROH-74, running as
   sequential passes ROH-101 → ROH-103) and Interface & Feel (ROH-45, ROH-50, ROH-53, ROH-54)
   are mid-flight. Both rewrite the ride recorder, the coordinator, the schema, the Live
   Activity, and the widget snapshot. Anything filed against them will collide.

An issue is in this lane when it clears all three: it builds and proves itself on one Mac plus
one iPhone, needs no backend write, and lives in files the two epics do not touch.

## Off the table, and why

Worth reading once so nothing here looks like an oversight.

- ROH-8, ROH-9, ROH-10, ROH-11, ROH-12, ROH-47, ROH-87, ROH-111 (Device Verification): all
  need the owner's device, a second identity, or both.
- ROH-108 (CloudKit production schema promotion): Urgent, and a release gate, but it is a
  console action inside the owner's Apple developer account.
- ROH-101, ROH-102, ROH-103, ROH-106, ROH-107, ROH-109, ROH-112: the pause epic. ROH-112 in
  particular reads like a tidy self-contained fix and is not. It depends on `pausedSeconds`
  presentation calls that Pass 4 and Pass 5 own.
- ROH-18 (distinct join-failure messages): the single generic error is deliberate. Splitting it
  means changing `join_ride`, which is a migration on the owner's project.
- ROH-66, ROH-17, ROH-73, ROH-80, ROH-20: group-ride work that needs a migration, a second
  device, or both.
- ROH-76 (MetricKit): the spec was killed at adversarial review on 2026-07-19. Do not restart
  it without the owner reopening the question.
- ROH-26 through ROH-30 (CarPlay, Watch, push-to-talk, Strava, sensors): each needs an
  entitlement or a third-party app registration under the owner's account.
- ROH-31, ROH-32, ROH-33: product calls that belong to the PO, and ROH-32 needs someone riding
  Pittsburgh hills.

## The lane

Ranked. The first two exist to prove the toolchain and the process on something small before
anything with real design surface in it.

| Issue | Size | Why it is safe to take |
|---|---|---|
| [ROH-104](https://linear.app/rohun/issue/ROH-104) | XS | Two `try?` in one file, no epic routes through it |
| [ROH-13](https://linear.app/rohun/issue/ROH-13) | S | Pure package tests, device-independent by definition |
| [ROH-113](https://linear.app/rohun/issue/ROH-113) | M | Contained AuraKit bug with genuine design work in it |
| [ROH-77](https://linear.app/rohun/issue/ROH-77) | M | Refactor for testability, no live backend needed |
| [ROH-115](https://linear.app/rohun/issue/ROH-115) | M | Profiling, answer first and fix only if warranted |
| [ROH-78](https://linear.app/rohun/issue/ROH-78) | M | Contained fix, but needs one PO answer up front |
| [ROH-14](https://linear.app/rohun/issue/ROH-14) | L | Real feature, self-contained, one device is enough |
| [ROH-21](https://linear.app/rohun/issue/ROH-21) | M | Lives entirely in AuraWidgets |
| [ROH-23](https://linear.app/rohun/issue/ROH-23) + [ROH-56](https://linear.app/rohun/issue/ROH-56) | M | Haptics pair, pure engine plus one setting |

### ROH-104 (Low, Bug) — swallowed decode failures in the migration plan

`RideMigrationPlan.swift:37` decodes the track with a bare `try?` and no `assertionFailure`,
four lines below a `statsData` branch that does assert. Line 39 swallows the thumbnail encode
the same way. A track that fails to decode silently leaves `thumbnailData` nil.

The catch worth knowing before starting: an `assertionFailure` here fires at container-open on
launch, so the fix has to be right about which failures are real bugs and which are legitimately
empty. The issue notes that `RideMigrationTests.swift:34` writes an empty encoded track that
decodes cleanly, so no existing test breaks.

### ROH-13 (Medium) — schema-invariant guard tests

Assert in package CI that every non-optional `RideRecord` attribute has a default and that
nothing carries `.unique` or a relationship, both of which break the CloudKit mirror. Then
confirm the frozen `RideSchemaV1` `.unique` never trips the mirror during the V1 to V2
`didMigrate`.

One correction to make before writing anything: the issue was filed against schema V2. The
schema is V6 now (ROH-100 added `segmentsData` and `pausedSeconds`). The test has to guard the
current shape, and it should be written so a future column that forgets its default fails in
package CI rather than at the CloudKit dashboard.

### ROH-113 (Medium) — a timed-out Overpass fetch poisons the gem cache

`CompositeGemProvider.livePath` races the live provider against a 2s timeout, then cancels.
The cancelled child keeps running: `LiveGemProvider.gems` wraps `session.data(for:)` in `try?`
so the cancellation is swallowed and the closure returns `[]`, and `GemRegionCache.gems` caches
that unconditionally with no `Task.isCancelled` check. One slow round trip caches zero gems for
that cell for ten minutes, with no retry and no signal.

The design work is real, not incidental: "no gems in this cell" is a legitimate cacheable
answer, so failure and emptiness have to become distinguishable before either fix works. Both
files are in `AuraCore/Sources/AuraKit/Gems/` and neither epic touches them.

### ROH-77 (Medium) — make the RPC error mapping testable

`SupabaseGroupRideBackend` maps Postgres `not host` and `not a member` raises to
`GroupRideError.notHost` and `.notMember`, which `GroupRideSession.finishRide` depends on for
its already-gone-is-success branch. The AuraKit tests structurally cannot catch a regression
because `InMemoryGroupRideBackend` throws the typed errors directly. A revert to a raw
`PostgrestError` would stay green and be dead in production, which is exactly the Critical this
came out of.

Take the first option in the issue: extract the mapping into a small testable helper and feed
it `PostgrestError`-shaped inputs. The second half of the issue, confirming at runtime that
supabase-swift puts the raw `RAISE` text in `PostgrestError.message`, needs a live round trip.
Leave that on the issue for the owner's next device pass and say so in the PR.

### ROH-115 (Low, Chore) — measure the ribbon's per-frame copying

`TrackRibbon.pieces(segments:)` maps every `TrackPoint` to a `Coordinate` for the whole ride,
then `routeRibbon` in `RideMapView` maps all of them again into `CLLocationCoordinate2D`, and
`RideHUDView` reads `@Observable` segments, so every recorded fix reruns both passes.

This one is a measurement, not a fix. ROH-105 retired a phantom performance number without
producing a real one, and the point here is to produce the real one before deciding whether
caching against a segment-count signature is worth it. Replaying the golden-ride fixture scaled
up is the cheap path. An honest "measured, it costs nothing, closing" is a good outcome.

### ROH-78 (Medium) — gate `onArrive` during a group ride

`NavigateHUDView` sets `guidance.onArrive = { endRide() }`, which runs the local finish
unconditionally. A host reaching the destination gets popped to the summary while `session.end()`
never fires, so guests wait in `.riding` until they leave or the ride expires.

The PO call the issue left open is answered as of 2026-07-29 and recorded on it: arrival
detaches that rider only, never ends the ride for everyone. It routes through the existing
member-leave path whether the arriving rider is the host or not.

That answer leaves one thing to resolve rather than absorb quietly. A host who arrives and
detaches leaves a live ride with no host in the HUD, and nothing fires `ride_ended` until the
ride expires or the last member leaves. Host transfer is ROH-17 and is out of scope, so either
keep the arriving host attached to the crew layer or name the gap in the PR and hand it to
ROH-17. The logic itself goes behind a pure helper with unit tests. Two-device confirmation
stays with the owner.

### ROH-14 (Medium) — QR-code join

The largest genuinely solo item on the board. `aura://join?code=` deep links and manual 8-char
entry already work, so this adds a camera scanner surface and a code display, not a protocol.
Testable alone by showing the QR on the simulator and scanning it with the phone. It needs
camera permission plumbing and a usage string, which is app-target work, not an account-level
capability.

### ROH-21 (Low) and ROH-22 — widget configurability

ROH-21 is `AppIntentConfiguration` over the existing static widgets and stays inside
AuraWidgets. Verify on the device or simulator. Skip ROH-22's push-reload half, which needs
APNs under the owner's account, unless the Control Center control is split out first.

### ROH-23 + ROH-56 (Low) — the haptics pair

ROH-23 turns the single 150 m approach cue into a multi-stage countdown, which is an extension
of the pure `TurnHapticEngine` plus its once-per-maneuver guard. ROH-56 adds a strength setting
covering both turn haptics and gem surfacing. They share the same files and the same device
verification session, so taking them together is cheaper than taking either alone. Feel is a
device-only judgment, and one phone is enough for it.

## Board discipline

Same rules as [BOARD.md](BOARD.md), plus two that only matter with more than one person on it:

- Assign the issue in Linear before starting, and move it to In Progress. That is how the other
  person knows not to pick it up. One In Progress issue at a time.
- Branch from `main` with the `gitBranchName` Linear generates for the issue, open a PR, and
  merge once CI is green. Do not push to `main`.

## Same process, on the other machine

Aura's development flow is not in the repo. It lives in the owner's user-scope Claude Code
configuration, so a fresh install produces sessions that skip every review gate and write Swift
from training-data recall. Four things have to be reproduced.

### 1. The standing mandates

Copy `~/.claude/CLAUDE.md` from the owner's machine, or recreate its four sections. They are the
whole process, and they override the default agent behavior on purpose:

- **Major feature work runs the full superpowers pipeline** with adversarial review gates:
  brainstorm, then 2 to 3 independent reviewer subagents with differing lenses against the spec,
  then a plan, then 2 or more reviewers against the plan, then subagent-driven implementation,
  then a whole-branch review. The gates are the part that gets skipped, and they are the part
  that has repeatedly caught defects that green tests and single-pass review missed.
- **Any Apple-platform work consults the matching iOS skill first**, before writing code from
  memory.
- **Any design or frontend work invokes the design skills.** Native SwiftUI surfaces use the iOS
  skills plus direct design judgment rather than the web tooling.
- **Any prose deliverable runs through `humanizer`.**

### 2. Plugins

Add the marketplaces, then install at user scope with `/plugin` in an interactive terminal:

| Plugin | Marketplace source |
|---|---|
| `superpowers` | `anthropics/claude-plugins-official` |
| `frontend-design` | `anthropics/claude-plugins-official` |
| `figma` | `anthropics/claude-plugins-official` |
| `all-ios-skills` | `dpearson2699/swift-ios-skills` |
| `apple-platform-build-tools` | `https://github.com/kylehughes/apple-platform-build-tools-claude-code-plugin.git` |
| `ios-build-verify` | `https://github.com/vermont42/ios-build-verify.git` |

`all-ios-skills` is the one that matters most day to day: 84 framework skills, routed by name.
`apple-platform-build-tools` provides the `builder` subagent that absorbs xcodebuild output, and
delegating builds to it is what keeps a session's context from filling with build logs.

### 3. The design skills

The 17 skills in the owner's `~/.claude/skills/` (`impeccable`, `emil-design-eng`,
`design-taste-frontend`, `humanizer`, and the rest) are loose directories, not marketplace
plugins. They have to be copied across. Ask the owner to archive that directory; there is no
install command for them.

### 4. Linear

The MCP connector is per-user OAuth. A Linear workspace invite does not give that person's
Claude Code access to the board. They authorize it themselves in claude.ai connector settings
or with `/mcp` in an interactive terminal. Until they do, their sessions cannot move issues,
and keeping the board honest is part of the flow rather than optional bookkeeping.

### Repo gates that are easy to trip

The three that cost the most time when missed:

- `xcodegen generate` after every clone, branch switch, and `project.yml` change. A stale
  project fails with `cannot find X in scope` in files you did not touch, which reads like
  broken code.
- SwiftLint pinned to 0.64.1, not Homebrew's current. `scripts/lint.sh` runs it. There is a
  custom rule banning `async` closure default arguments (ROH-110); if it fires, default the
  parameter to nil and build the closure inside the module rather than working around the rule.
- `swift test --no-parallel` in `AuraCore`. Any new suite that builds a SwiftData container
  needs the `.swiftDataSerialized` trait, or it flakes against every other suite that registers
  the same entity descriptions. `scripts/golden-ride.sh` is the local end-to-end ride gate.

## A daily routine of your own

The owner has a private artifact that reads the live board each morning and lays out about six
development routes, each with a copy-ready session-start prompt. Same idea works here, filtered
to the independent lane so nothing surfaces that needs a second phone.

Paste this into a fresh Claude Code session in the Aura repo, once. Authorize the Linear
connector first, or it will build the page against a board it cannot read.

```
Set up a daily "Aura dev routes" briefing for me, the same way the repo describes in
docs/COLLABORATOR-TASKS.md.

Build it in two parts:

1. A private web artifact. Read docs/COLLABORATOR-TASKS.md and docs/BOARD.md first, then
   query the live Linear board (workspace linear.app/rohun, team "Rohun", key ROH) for
   Todo / In Progress / Backlog issues and the projects. Lay out about five development
   routes I could take today, ranked, with the strongest as a featured pick. For each
   route give me: the ROH issue IDs linked to linear.app, a one-line "why now", an
   effort and risk line, the current state chip, and a fully self-contained session-start
   prompt in a collapsible block that I can copy into a fresh session.

   Filter hard. Only surface issues that pass the three independence gates in
   COLLABORATOR-TASKS.md: no second device or second Apple ID, no Supabase migration or
   Apple-account action, and no collision with the Pause & Segmented Rides epic (ROH-74,
   passes ROH-101 to ROH-103) or the Interface & Feel epic (ROH-45, ROH-50, ROH-53,
   ROH-54). If an issue is assigned to someone else or already In Progress, leave it out.
   If fewer than five qualify, show fewer and say so rather than padding the list.

   Every generated prompt must tell the new session to follow the Aura dev flow: move the
   Linear issue to In Progress before starting, run the full superpowers pipeline with
   adversarial review gates for anything non-trivial, consult the matching all-ios-skills
   skill before writing Swift, and verify on the device where the change is device-visible.

   Design it dark with a lime #C8FA4B accent and monospace issue IDs, matching Aura's own
   identity. Load the artifact-design skill before you write the page. Save the HTML to
   ~/.claude/artifacts/aura-dev-routes.html and publish it with the Artifact tool. Tell me
   the URL it lands on.

2. A scheduled task named aura-dev-routes that reruns this every morning at 7am and
   redeploys to that same artifact URL by passing it as the `url` parameter, so the link
   never changes. The task must re-query Linear each run, re-derive the routes against the
   same filter, and preserve the page design rather than redesigning it. If the Linear
   connector is not authorized in a given run, it should refresh what it can, republish,
   and say clearly that the board could not be reached and the routes may be stale.

Then run the task once so I can approve the Linear and Artifact tool calls up front.
```

Two things about the scheduled task worth knowing: it fires only while the app is open, and
catches up on the next launch if it missed. And the "run it once now" step at the end is not
optional. Approving those tool calls interactively is what lets the unattended runs work.
