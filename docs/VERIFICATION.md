# Verification policy — what gets a device pass, and what Claude verifies itself

Every change gets verified at exactly one of three tiers before it is called done. The tier
is decided by what the change *touches*, not by how confident anyone feels about it. A PR
states its tier and its evidence in the body; a PR that mixes tiers takes the highest tier
of any of its parts.

The point of the tiers: device passes are expensive (they need Rohun, a ride, and often a
second phone), so they are reserved for the classes of behavior that have actually required
a device to catch in this repo. Everything else Claude verifies and calls, with evidence.

## Tier 0 — gate-only

Pure logic in AuraCore/AuraKit with unit tests, refactors that change no behavior, comments
and docs, CI/tooling/scripts, migrations covered by pgTAP.

**Evidence:** the quality gate — package tests + SwiftLint, plus an app build when the app
target is touched. No screenshots.

## Tier 1 — Claude verifies in the simulator, and that's the call

Any change whose correctness is visible in a screen state or drivable by tap:

- Layout, spacing, styling, color, typography, icons, badges, UX copy
- New or changed screens, cards, sheets, empty states, summary and share surfaces
- Simple interactions: expand/collapse, toggles, button states, navigation pushes and pops
- Ride-screen changes where the behavior is geometry rather than sensor feel — drive them
  with simulated location playback (a real mapped route at ride speed, the
  `simctl location` / GPX recipe), not by staring at a static screen

**Evidence:** simulator screenshots of the states the change is about — the changed state
itself, plus dark mode / large Dynamic Type when the change plausibly interacts with them —
attached to the PR. Where a golden-ride or XCUITest already covers the flow, cite it.

**Merge:** on CI green. No device pass is owed. Rohun can always ask for a device look at
anything; that request never needs justifying.

## Tier 2 — device pass required

The device-only list. Every line is here because a simulator pass missed (or could not have
caught) a real defect in this repo:

- GPS/location behavior, heading/bearing/camera-dependent rendering (ROH-213: the peer
  pointer was wrong only on a rotated course-up map), location lifecycle tiers (ROH-83)
- Two-phone group-ride behavior: presence, realtime transport, join/leave/end lifecycle
  (the uppercase-topic bug, ROH-81's end-that-never-ended)
- Haptics and voice audio (including ducking), and anything about *feel while riding* —
  tap targets, glare and legibility, animation smoothness on hardware (ROH-75)
- Background recording, app kill/restore, locked screen, StandBy (ROH-144, ROH-107)
- Widgets, Live Activities, Dynamic Island (ROH-102, ROH-124)
- HealthKit writes, iCloud sync, push notifications
- Structural NavigationStack changes — the double-mutation reconciliation trap only
  manifests on device

**Evidence:** Claude still does the best simulator verification available and attaches it;
the device pass covers what the simulator cannot.

**Merge:** on CI green plus that best-effort simulator verification. The device check is
queued, not blocking: file a `Verification`-labeled Linear issue named for the change,
listing exactly what to look at, so the next ride covers every queued check in one pass.
The PR body links the issue. The change's own feature issue can close on merge; the
Verification issue is the record that the device look is still owed.

**The one exception:** if Claude is genuinely unsure the change is *correct* without a
device — not merely unverified, but plausibly wrong in a way only hardware will reveal —
it says so and holds the merge (the ROH-101/ROH-102 pattern). That flag is the exception,
not the default, and the PR must state why.

## Mechanics

- The PR body carries a `Verification: Tier N` line with the evidence (screenshots, test
  citations, or the linked Verification issue).
- Claude drives the simulator itself — build, launch, navigate, screenshot, location
  playback — rather than asking Rohun to check things a simulator can show.
- [DEVICE-TESTING.md](DEVICE-TESTING.md) remains the full manual regression script for
  release-shaped passes; this file governs per-change verification. When a Tier 2 change
  alters what a device pass should look for, update DEVICE-TESTING.md in the same PR.
- Verification issues that a ride confirms get closed with a one-line result; anything the
  ride disproves becomes a Bug issue on the spot.
