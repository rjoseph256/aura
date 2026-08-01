# Active time on the ride summary (ROH-112) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The ride summary leads with active time (`elapsed - paused`), the number the rider watched on the HUD, with elapsed as a subordinate caption and the existing moving-time cell retained.

**Architecture:** One pure `RideDuration` type in AuraCore owns the finished ride's two durations and hosts the single definition of active time that both live clocks are rewired to call, with a checked-in guard script keeping it single. A pure `RideSummaryStats` in AuraKit resolves the summary's three stat cells to display strings from scalars, and `RideSummaryView` becomes a projection of it. One string changes in the Dynamic Island so "elapsed" stops naming two different numbers.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`) for package tests, XCTest/XCUITest for the E2E.

Spec: `docs/superpowers/specs/2026-08-01-roh112-active-time-design.md` (revision 3).

Status: revision 2, after a two-reviewer gate. Revision 1 disqualified every ride carrying a checkpoint marker, which would have shown `—` to a rider whose ride failed to save; rewired only one of `RideActiveClock`'s two derivations of active time, leaving the rendered one behind; described the Live Activity change on a surface that does not carry the string; and ran the package suite the flaky way. Corrections are inline.

## Global Constraints

- **The moving cell keeps its identifier, its label, and its value.** `RideTestID.summaryMoving` and the label `"moving"` are unchanged, and the value must stay `RideStatsFormatter(units: settings.units).minutes(stats.movingTimeSeconds)` however it is spelled. `RideE2EUITests.assertMovingTimeIsSegmented` is a CI gate that reads it. *(Revision 2: revision 1 said "byte-identical value expression", which Task 4 then violated by routing it through `RideSummaryStats`. The behavior is what matters.)*
- **`RideActiveClock.make` and `RideSessionCoordinator.refreshElapsed` change implementation, never behavior.** Their existing tests, which pin frozen literals, are the guard.
- **Scope is the ride summary plus one Dynamic Island string.** The History caption, the Home last-ride card, the widget, and the share card stay on moving time (ROH-146). Do not edit `HistoryView.swift`, `LastRideCard.swift`, `LastRideWidget.swift`, `WidgetSnapshot.swift`, `ShareCardContent.swift`, or `ShareCardView.swift`.
- **Copy is exact:** cell label `active`, caption `"<N> min elapsed"`, Dynamic Island running label `ACTIVE`.
- **Package tests must pass on the macOS CI host**, so nothing in AuraCore/AuraKit may import SwiftUI, UIKit, or WidgetKit.
- **Full package runs use `swift test --no-parallel --package-path AuraCore`.** A bare `swift test` races the SwiftData suites (`.claude/agent-gate.sh:19-20`, `.github/workflows/ci.yml:50`). Filtered runs may omit it.
- A package run prints **two totals: an XCTest one and a swift-testing one**, not one per target. The XCTest line reading `Executed 0 tests` is normal — every suite here is swift-testing.
- Lint with `swiftlint --strict` run **from the repo root**, after every task that touches a `.swift` file.

---

## File Structure

| File | Responsibility |
| -- | -- |
| `AuraCore/Sources/AuraCore/Ride/RideDuration.swift` (create) | The finished ride's `elapsedSeconds`/`activeSeconds`, plus `activeSeconds(startedAt:asOf:pausedSeconds:)`, the one definition of active time. Also `Ride.duration`. |
| `AuraCore/Tests/AuraCoreTests/RideDurationTests.swift` (create) | Task 1 coverage. |
| `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift` (modify) | Both derivations route through the primitive. |
| `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` (modify) | Route through the primitive. |
| `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift` (create) | Both clock branches agree with the primitive. |
| `scripts/check-single-active-definition.sh` (create) | Fails the build if anything re-derives active time. |
| `.claude/agent-gate.sh` (modify) | Run the guard alongside the two existing ones. |
| `.github/workflows/ci.yml` (modify) | Same guard in CI. |
| `AuraCore/Sources/AuraKit/Formatting/RideSummaryStats.swift` (create) | The summary's three cells as display strings, from scalars. |
| `AuraCore/Tests/AuraKitTests/RideSummaryStatsTests.swift` (create) | Task 3 coverage. |
| `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift` (modify) | `RideTestID.summaryActive`. |
| `Aura/Sources/Ride/RideSummaryView.swift` (modify) | Project `RideSummaryStats` into three cells. |
| `Aura/Widgets/RideLiveActivity.swift` (modify) | `ELAPSED` becomes `ACTIVE`. |
| `Aura/UITests/Screens/Screens.swift` (modify) | `SummaryScreen.activeStat`. |
| `Aura/UITests/RideE2EUITests.swift` (modify) | `assertActiveIsNotTheMovingNumber`. |

---

### Task 1: `RideDuration`, the pure finished-ride duration

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/RideDuration.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideDurationTests.swift`

**Interfaces:**
- Consumes: `Ride` (`AuraCore/Sources/AuraCore/Models/Ride.swift`), which has `startedAt: Date`, `endedAt: Date?`, `checkpointedAt: Date?`, `pausedSeconds: TimeInterval`.
- Produces:
  - `RideDuration.init?(startedAt: Date, endedAt: Date?, checkpointedAt: Date?, pausedSeconds: TimeInterval)`
  - `RideDuration.elapsedSeconds: TimeInterval`, `RideDuration.activeSeconds: TimeInterval`
  - `RideDuration.activeSeconds(startedAt: Date, asOf: Date, pausedSeconds: TimeInterval) -> TimeInterval` (static)
  - `Ride.duration: RideDuration?`

There is deliberately **no `RideSummary.duration`**. Its only consumers, History and the Home last-ride card, are out of scope (ROH-146 adds it when they move). *(Revision 2: revision 1 shipped it with no caller but its own test.)*

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/RideDurationTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("Ride duration")
struct RideDurationTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("Active time is elapsed less the time spent paused")
    func activeIsElapsedLessPaused() throws {
        let d = try #require(RideDuration(startedAt: start,
                                          endedAt: start.addingTimeInterval(2880),
                                          checkpointedAt: nil, pausedSeconds: 600))
        #expect(d.elapsedSeconds == 2880)
        #expect(d.activeSeconds == 2280)
    }

    @Test("A ride with no recorded pauses reports active equal to elapsed")
    func noPausesMeansActiveIsElapsed() throws {
        // Every ride recorded before pause existed, and every ride the rider never paused.
        let d = try #require(RideDuration(startedAt: start,
                                          endedAt: start.addingTimeInterval(2880),
                                          checkpointedAt: nil, pausedSeconds: 0))
        #expect(d.activeSeconds == d.elapsedSeconds)
    }

    @Test("A checkpoint row — endedAt stamped AT the pause — is disqualified")
    func checkpointRowIsDisqualified() {
        // `RideRecorder.checkpoint(at:)` writes endedAt and checkpointedAt to the SAME instant.
        // The rider may have resumed and ridden for another hour before the kill, so this
        // interval can be a fraction of the real ride.
        let end = start.addingTimeInterval(1800)
        #expect(RideDuration(startedAt: start, endedAt: end,
                             checkpointedAt: end, pausedSeconds: 0) == nil)
    }

    @Test("A ride that failed to save still reports its real duration")
    func saveFailureRideKeepsItsDuration() throws {
        // `RideSessionCoordinator.finish()`'s catch branch restores the MARKER onto a ride whose
        // endedAt came from `RideRecorder.end(at:)` — the real End tap, strictly after the
        // checkpoint. Both durations are exactly known, and the rider is looking at this summary
        // right now. Disqualifying it would print "—" beside a real distance and a real top speed.
        // Pinned against `RideSessionCheckpointFlushTests.swift:238`, which asserts this ride is
        // "still a real duration".
        let d = try #require(RideDuration(startedAt: start,
                                          endedAt: start.addingTimeInterval(5400),
                                          checkpointedAt: start.addingTimeInterval(1800),
                                          pausedSeconds: 600))
        #expect(d.elapsedSeconds == 5400)
        #expect(d.activeSeconds == 4800)
    }

    @Test("A ride with no end at all has no duration")
    func noEndMeansNoDuration() {
        // The legacy PR #90 dev-build rows: nil endedAt and no marker.
        #expect(RideDuration(startedAt: start, endedAt: nil,
                             checkpointedAt: nil, pausedSeconds: 0) == nil)
    }

    @Test("Active never exceeds elapsed, whatever the stored paused seconds say")
    func activeIsBoundedByElapsed() throws {
        // Unlike the live clocks, this reads a persisted, CloudKit-mirrored Double column
        // (`RideSchemaV7.swift:42`). A negative value would render active ABOVE elapsed with the
        // caption present to make it unmissable; an oversized one would zero the headline.
        for paused in [-500.0, 900.0] {
            let d = try #require(RideDuration(startedAt: start,
                                              endedAt: start.addingTimeInterval(600),
                                              checkpointedAt: nil, pausedSeconds: paused))
            #expect(d.activeSeconds >= 0)
            #expect(d.activeSeconds <= d.elapsedSeconds)
        }
    }

    @Test("The shared primitive is what every clock in the app subtracts with")
    func sharedPrimitiveSubtractsPausedTime() {
        let now = start.addingTimeInterval(1000)
        #expect(RideDuration.activeSeconds(startedAt: start, asOf: now,
                                           pausedSeconds: 250) == 750)
        #expect(RideDuration.activeSeconds(startedAt: start, asOf: now,
                                           pausedSeconds: 5000) == 0)
    }

    @Test("A Ride projects its own duration")
    func rideProjectsItsDuration() throws {
        let end = start.addingTimeInterval(2880)
        let ride = Ride(kind: .freeRide, startedAt: start, endedAt: end, track: [],
                        stats: nil, pausedSeconds: 600, checkpointedAt: nil,
                        routeId: nil, destinationPlaceId: nil)
        #expect(try #require(ride.duration).activeSeconds == 2280)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path AuraCore --filter RideDurationTests`
Expected: FAIL to compile, "cannot find 'RideDuration' in scope".

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraCore/Ride/RideDuration.swift`:

```swift
import Foundation

/// A finished ride's two durations.
///
/// The counterpart of `RideActiveClock`, which answers the same question while the ride is still
/// running. Both route through `activeSeconds(startedAt:asOf:pausedSeconds:)` below, so the number
/// the rider watched on the HUD and the number the summary shows cannot drift (parent spec D5).
public struct RideDuration: Equatable, Sendable {
    /// Wall clock from the start of the ride to its end.
    public let elapsedSeconds: TimeInterval
    /// `elapsedSeconds` less the time the rider spent paused. Equal to elapsed on any ride with no
    /// recorded pauses, which includes every ride recorded before pause existed.
    public let activeSeconds: TimeInterval

    /// Nil when this ride's end instant cannot be trusted as the end of the *riding*.
    ///
    /// **This is deliberately NOT `isUnfinished`, and must not be "corrected" into it.**
    /// `Ride.isUnfinished` is `checkpointedAt != nil || endedAt == nil`, and two different rides
    /// satisfy its first clause:
    ///
    /// - **A checkpoint row.** `RideRecorder.checkpoint(at:)` writes `endedAt` and
    ///   `checkpointedAt` to the *same* instant, the pause. The rider may have resumed and ridden
    ///   for another hour before the kill, so the interval can be a fraction of the real ride.
    ///   Reporting "30 min" for a 90-minute ride is confidently wrong in a way the unfinished
    ///   badge does not cover: a rider reads that badge as "the last bit is missing".
    /// - **A ride that failed to save.** `RideSessionCoordinator.finish()`'s catch branch restores
    ///   the marker onto a ride whose `endedAt` came from `RideRecorder.end(at:)` — the real End
    ///   tap, strictly *after* the checkpoint. Both durations are exactly known, and this is the
    ///   summary the rider is looking at the moment their ride failed to save. Blanking it there,
    ///   beside a real distance and a real top speed, reads as "the app lost my ride".
    ///
    /// So the disqualifier is `checkpointedAt >= endedAt`, which selects the first and spares the
    /// second. `RideSessionCheckpointFlushTests.swift:238` asserts the second is "still a real
    /// duration"; this rule is what keeps that true.
    ///
    /// A nil `endedAt` with no marker is the legacy PR #90 dev-build row, also nil here.
    public init?(startedAt: Date, endedAt: Date?, checkpointedAt: Date?,
                 pausedSeconds: TimeInterval) {
        guard let endedAt else { return nil }
        if let checkpointedAt, checkpointedAt >= endedAt { return nil }

        // Clamped, and NOT asserted. Revision 1 trapped here on the theory that only a degenerate
        // recorder state produces it; tracing `checkpoint(at:)` and `end(at:)` shows neither can
        // (both collapse to a zero interval, not a negative one). The real producer is a backward
        // wall-clock step, which this repo has open as ROH-130 — and unlike
        // `RideMigrationPlan`'s assertion, which runs once over local data inside a migration,
        // this runs inside `RideSummaryView.body` over rows CloudKit mirrored from another
        // device. A trap there fails the summary screen, the UI-test suite, and the device pass
        // for a clock skew the app already knows it does not handle.
        let elapsed = max(0, endedAt.timeIntervalSince(startedAt))
        elapsedSeconds = elapsed

        // The persisted column is sanitized HERE, not inside the shared primitive: the two live
        // clocks read `RideRecorder.pausedSeconds(asOf:)`, which is structurally non-negative and
        // bounded by the session, while this reads a CloudKit-mirrored `Double`
        // (`RideSchemaV7.swift:42`). Without this, a negative value renders active ABOVE elapsed,
        // with the caption present to make it unmissable.
        activeSeconds = RideDuration.activeSeconds(
            startedAt: startedAt, asOf: endedAt,
            pausedSeconds: min(max(0, pausedSeconds), elapsed))
    }

    /// **The one definition of active time**: wall clock since the start, less time spent paused.
    ///
    /// Every clock calls this and nothing re-derives it — the HUD's live number
    /// (`RideSessionCoordinator.refreshElapsed`), both branches of the Live Activity's
    /// (`RideActiveClock.make`), and the finished ride's (`init` above). Parent spec D5 makes
    /// their agreement a product requirement: the rider must see the same clock after the ride
    /// that they watched during it. `scripts/check-single-active-definition.sh` is what keeps
    /// that true, because a doc comment asking future authors not to re-derive it is exactly the
    /// kind of request this repo has watched get ignored.
    ///
    /// For a running ride `pausedSeconds` must be measured as of `now`, including a stop still
    /// open; see `RideActiveClock.make`.
    public static func activeSeconds(startedAt: Date, asOf now: Date,
                                     pausedSeconds: TimeInterval) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt) - pausedSeconds)
    }
}

extension Ride {
    /// This ride's durations, or nil when its end instant cannot be trusted. See
    /// `RideDuration.init`, which explains why this is not `isUnfinished`.
    public var duration: RideDuration? {
        RideDuration(startedAt: startedAt, endedAt: endedAt,
                     checkpointedAt: checkpointedAt, pausedSeconds: pausedSeconds)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path AuraCore --filter RideDurationTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --strict
git add AuraCore/Sources/AuraCore/Ride/RideDuration.swift AuraCore/Tests/AuraCoreTests/RideDurationTests.swift
git commit -m "feat(roh-112): add RideDuration, the one definition of active time"
```

---

### Task 2: Route every clock through the primitive, and keep it that way

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift:43` and `:54`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:224`
- Create: `scripts/check-single-active-definition.sh`
- Modify: `.claude/agent-gate.sh` (beside the two existing guards at `:80` and `:83`)
- Modify: `.github/workflows/ci.yml`
- Test: `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift` (create)

**Interfaces:**
- Consumes: `RideDuration.activeSeconds(startedAt:asOf:pausedSeconds:)` from Task 1.
- Produces: no new API. Behavior is unchanged by construction.

`RideActiveClock.make` has **two** derivations of active time, not one, and revision 1 rewired only the first. `:43` computes `activeSeconds`, which is *discarded* on the running branch; `:54` separately derives the anchor the Lock Screen and Dynamic Island actually render. The rendered one is the one that mattered.

- [ ] **Step 1: Write the agreement test**

Create `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

/// Both branches of the Live Activity's clock, and the finished ride's, must report the same
/// active time for the same inputs. Parent spec D5 rests on it: the rider sees the number they
/// watched when they pressed End.
///
/// **What this catches and what it does not.** After the rewire both sides of these expectations
/// call the same function, so this cannot fail for a change to the *definition* of active time —
/// `RideActiveClockTests` pins that against frozen literals, and
/// `scripts/check-single-active-definition.sh` is what stops a new derivation appearing. What it
/// does catch is a future author re-inlining either branch of `make`, which is precisely how
/// revision 1 of this plan left the rendered anchor behind.
///
/// The HUD's own clock (`RideSessionCoordinator.refreshElapsed`) is the third caller and is not
/// tested here: its `startedAt` is private and stamped from `Date()`, so a test cannot supply both
/// sides. The guard script is what holds it, and `RideSessionCoordinatorPauseTests` its behavior.
@Suite("Active time agreement")
struct ActiveTimeAgreementTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let pausedCases: [TimeInterval] = [0, 240, 5000]

    @Test("The paused clock's active reading matches the primitive")
    func pausedClockMatchesPrimitive() {
        let now = start.addingTimeInterval(900)
        for paused in pausedCases {
            let clock = RideActiveClock.make(startedAt: start, pausedSeconds: paused,
                                             pausedSince: now, now: now)
            guard case .paused(_, let activeSeconds) = clock else {
                Issue.record("expected a paused clock for paused: \(paused)")
                continue
            }
            #expect(activeSeconds == RideDuration.activeSeconds(startedAt: start, asOf: now,
                                                                pausedSeconds: paused))
        }
    }

    @Test("The running anchor is `now` less the active seconds — this is the branch that renders")
    func runningAnchorMatchesPrimitive() {
        // `Text(anchor, style: .timer)` counts up from the anchor, so the rendered number is
        // `now - anchor`. That, not the discarded `activeSeconds` local, is what the rider sees.
        let now = start.addingTimeInterval(900)
        for paused in pausedCases {
            let clock = RideActiveClock.make(startedAt: start, pausedSeconds: paused,
                                             pausedSince: nil, now: now)
            guard case .running(let anchor) = clock else {
                Issue.record("expected a running clock for paused: \(paused)")
                continue
            }
            #expect(now.timeIntervalSince(anchor)
                    == RideDuration.activeSeconds(startedAt: start, asOf: now,
                                                  pausedSeconds: paused))
        }
    }

    @Test("A finished ride's active time matches the primitive at its end instant")
    func finishedRideMatchesPrimitive() throws {
        let end = start.addingTimeInterval(2880)
        let d = try #require(RideDuration(startedAt: start, endedAt: end,
                                          checkpointedAt: nil, pausedSeconds: 600))
        #expect(d.activeSeconds == RideDuration.activeSeconds(startedAt: start, asOf: end,
                                                              pausedSeconds: 600))
    }
}
```

- [ ] **Step 2: Run it and confirm it passes against the current code**

Run: `swift test --package-path AuraCore --filter ActiveTimeAgreementTests`
Expected: PASS. The existing derivations already agree; the test exists to keep them agreeing.

If `runningAnchorMatchesPrimitive` fails here, stop and report — that would mean the two current derivations already disagree, which is a bug this task did not expect to find.

- [ ] **Step 3: Rewire `RideActiveClock.make`, both branches**

In `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift`, replace line 43:

```swift
        let activeSeconds = max(0, now.timeIntervalSince(startedAt) - pausedSeconds)
```

with:

```swift
        let activeSeconds = RideDuration.activeSeconds(startedAt: startedAt, asOf: now,
                                                       pausedSeconds: pausedSeconds)
```

Then replace the running return at line 54 and amend the comment block above it (`:47-53`) so it
describes the form that is actually there. Replace lines 47-54 in full with:

```swift
        // Anchored at `now` less the active seconds, which is identical to
        // `startedAt + pausedSeconds` whenever that is in the past, and equal to `now` when it is
        // not: a backward wall-clock step can push `startedAt + pausedSeconds` past `now`, and
        // `Text(_, style: .timer)` with a future anchor counts DOWN. The clamp now lives inside
        // `RideDuration.activeSeconds`, which is why this reads as a subtraction from `now`
        // rather than an addition to `startedAt`. While it is active the anchor tracks `now` and
        // the clock reads 0:00, which costs a push per coalescing interval until wall-clock
        // catches up — bounded by the size of the backward step, and strictly better than a Lock
        // Screen counting down. The in-app clock clamps for the same reason
        // (`RideSessionCoordinator.refreshElapsed`); the residual wall-clock weakness is ROH-130.
        return .running(anchor: now.addingTimeInterval(-activeSeconds))
```

- [ ] **Step 4: Rewire `refreshElapsed`**

In `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`, in `refreshElapsed(now:)`, replace:

```swift
        elapsed = max(0, now.timeIntervalSince(startedAt) - recorder.pausedSeconds(asOf: now))
```

with:

```swift
        elapsed = RideDuration.activeSeconds(startedAt: startedAt, asOf: now,
                                             pausedSeconds: recorder.pausedSeconds(asOf: now))
```

Leave the `currentPauseSeconds` line and every comment unchanged.

- [ ] **Step 5: Write the guard script**

Create `scripts/check-single-active-definition.sh`, matching the shape of the two guards already
in `scripts/`:

```bash
#!/usr/bin/env bash
# Active time has exactly one definition: `RideDuration.activeSeconds`.
#
# Three clocks compute it — the HUD's, both branches of the Live Activity's, and the finished
# ride's — and parent spec D5 requires that they agree, because the rider must see the same clock
# after the ride that they watched during it. Two of them were separately-written subtractions
# until ROH-112, and the rendered one was nearly missed. A comment asking future authors not to
# re-derive it is the kind of request this repo has watched get ignored, so this is a build gate.
set -euo pipefail
cd "$(dirname "$0")/.."

offenders=$(grep -rnE \
  '(-[[:space:]]*[A-Za-z_.]*[Pp]ausedSeconds)|(addingTimeInterval\([A-Za-z_.]*[Pp]ausedSeconds)' \
  --include='*.swift' AuraCore/Sources Aura/Sources Aura/Widgets \
  | grep -vE ':[[:space:]]*//' \
  | grep -v 'AuraCore/Sources/AuraCore/Ride/RideDuration.swift' || true)

if [ -n "$offenders" ]; then
  echo "Active time must come from RideDuration.activeSeconds. Re-derived at:"
  echo "$offenders"
  exit 1
fi
```

Then `chmod +x scripts/check-single-active-definition.sh`.

- [ ] **Step 6: Run the guard**

Run: `bash scripts/check-single-active-definition.sh; echo "exit: $?"`
Expected: no output, exit 0. Before Steps 3-4 it reported three offenders
(`RideSessionCoordinator.swift:224`, `RideActiveClock.swift:43`, `:54`); all three are now calls
rather than derivations.

- [ ] **Step 7: Wire the guard into the gate and CI**

In `.claude/agent-gate.sh`, beside the existing guards (`:80`, `:83`), add:

```bash
  run "single active-time definition" . bash scripts/check-single-active-definition.sh
```

In `.github/workflows/ci.yml`, add a step in the same job as the other guard scripts:

```yaml
      - name: Single active-time definition guard
        run: bash scripts/check-single-active-definition.sh
```

Match the surrounding steps' indentation and naming style exactly; read the neighbours first.

- [ ] **Step 8: Run the full package suite**

Run: `swift test --no-parallel --package-path AuraCore`
Expected: PASS. `RideActiveClockTests` (frozen literals, including the `.running` anchor) and
`RideSessionCoordinatorPauseTests` are the guard that behavior did not move.

- [ ] **Step 9: Lint and commit**

```bash
swiftlint --strict
git add AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift \
        AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift \
        AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift \
        scripts/check-single-active-definition.sh .claude/agent-gate.sh .github/workflows/ci.yml
git commit -m "refactor(roh-112): one definition of active time, enforced by a build gate"
```

---

### Task 3: `RideSummaryStats`, the summary's stat row as display strings

**Files:**
- Create: `AuraCore/Sources/AuraKit/Formatting/RideSummaryStats.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSummaryStatsTests.swift`

**Interfaces:**
- Consumes: `RideDuration` (Task 1), `RideStatsFormatter` (`AuraKit/Formatting/RideStatsFormatter.swift`), `DistanceUnits` (`AuraKit/Settings/SettingsStore.swift`).
- Produces: `RideSummaryStats(duration:movingTimeSeconds:maxSpeedMetersPerSecond:units:)` with `activeValue: String`, `elapsedCaption: String?`, `activeAccessibilityLabel: String`, `movingValue: String`, `topSpeedValue: String`, `topSpeedLabel: String`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraKitTests/RideSummaryStatsTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite("Ride summary stats")
struct RideSummaryStatsTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func duration(elapsed: TimeInterval, paused: TimeInterval) -> RideDuration? {
        RideDuration(startedAt: start, endedAt: start.addingTimeInterval(elapsed),
                     checkpointedAt: nil, pausedSeconds: paused)
    }

    private func stats(_ d: RideDuration?, units: DistanceUnits = .imperial) -> RideSummaryStats {
        RideSummaryStats(duration: d, movingTimeSeconds: 1860,
                         maxSpeedMetersPerSecond: 10.86, units: units)
    }

    @Test("A paused ride shows active with elapsed beneath it")
    func pausedRideShowsThePair() {
        let s = stats(duration(elapsed: 2880, paused: 600))
        #expect(s.activeValue == "38 min")
        #expect(s.elapsedCaption == "48 min elapsed")
        #expect(s.activeAccessibilityLabel == "Active time, 38 min. Elapsed, 48 min.")
    }

    @Test("An unpaused ride shows no elapsed caption")
    func unpausedRideHidesTheCaption() {
        // The majority path. A fixed layout would print the same number twice, permanently.
        let s = stats(duration(elapsed: 2880, paused: 0))
        #expect(s.activeValue == "48 min")
        #expect(s.elapsedCaption == nil)
        #expect(s.activeAccessibilityLabel == "Active time, 48 min.")
    }

    @Test("A pause too short to change the rendered minute shows no caption either")
    func subMinutePauseHidesTheCaption() {
        // `RideStatsFormatter.minutes` truncates, so 2870 s and 2850 s both render "47 min"
        // despite a real 20 s pause. Comparing RENDERED STRINGS rather than `pausedSeconds > 0`
        // is what covers this case.
        let s = stats(duration(elapsed: 2870, paused: 20))
        #expect(s.activeValue == "47 min")
        #expect(s.elapsedCaption == nil)
    }

    @Test("A ride with no trustworthy end shows a dash and no caption")
    func unavailableDurationIsDashed() {
        let s = stats(nil)
        #expect(s.activeValue == "—")
        #expect(s.elapsedCaption == nil)
        #expect(s.activeAccessibilityLabel == "Active time, unavailable.")
    }

    @Test("Moving time and top speed are unchanged by any of this")
    func movingAndTopSpeedAreUntouched() {
        let s = stats(duration(elapsed: 2880, paused: 600))
        #expect(s.movingValue == "31 min")
        #expect(s.topSpeedValue == "24.3")
        #expect(s.topSpeedLabel == "mph top")
        #expect(stats(duration(elapsed: 2880, paused: 600), units: .metric).topSpeedLabel
                == "km/h top")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path AuraCore --filter RideSummaryStatsTests`
Expected: FAIL to compile, "cannot find 'RideSummaryStats' in scope".

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraKit/Formatting/RideSummaryStats.swift`:

```swift
import Foundation
import AuraCore

/// The ride summary's supporting stat row, resolved to display-ready strings in the pure layer so
/// the branching is unit tested without the app target. `RideSummaryView`'s row is a projection
/// of this.
///
/// **Takes scalars, never a `Ride`.** The view builds this during `body`, and this project's rule
/// (see `RideSummaryView.swift:52`) is that nothing track-derived is read there. A type holding a
/// whole ride invites the next author to add one `flattenedPoints`-derived field and hand the
/// summary an O(n) walk on every body evaluation — which is exactly why `ShareCardContent`, the
/// other type of this shape, is built in a `.task` instead.
public struct RideSummaryStats: Equatable, Sendable {
    /// "38 min", or "—" when the ride's end instant cannot be trusted (see `RideDuration.init`).
    public let activeValue: String
    /// "48 min elapsed", or nil when it would merely repeat `activeValue`.
    public let elapsedCaption: String?
    /// One explicit spoken label, rather than `children: .combine` over a value, a label and a
    /// caption, whose composed order is a layout detail.
    public let activeAccessibilityLabel: String
    public let movingValue: String
    public let topSpeedValue: String
    public let topSpeedLabel: String

    public init(duration: RideDuration?, movingTimeSeconds: Double,
                maxSpeedMetersPerSecond: Double, units: DistanceUnits) {
        let fmt = RideStatsFormatter(units: units)
        movingValue = fmt.minutes(movingTimeSeconds)
        topSpeedValue = fmt.speedValue(maxSpeedMetersPerSecond, decimals: 1)
        // Composed from the formatter's own unit rather than a second `units == .metric` ternary,
        // so "km/h" has one source.
        topSpeedLabel = "\(fmt.speedUnit) top"

        guard let duration else {
            activeValue = "—"
            elapsedCaption = nil
            activeAccessibilityLabel = "Active time, unavailable."
            return
        }

        let active = fmt.minutes(duration.activeSeconds)
        let elapsed = fmt.minutes(duration.elapsedSeconds)
        activeValue = active
        // Compared as RENDERED STRINGS, not on `pausedSeconds > 0`: `minutes` truncates, so a
        // pause that does not cross a minute boundary also renders the same number twice. On an
        // unpaused ride — the majority path, and every ride recorded before pause existed — the
        // two are equal by definition, and stacking a number under itself tells the rider nothing.
        //
        // The caption's absence is therefore ambiguous in a third way worth knowing about: until
        // ROH-108 promotes the CloudKit PRODUCTION schema, `CD_pausedSeconds` does not mirror, so
        // a ride paused on one phone shows the pair on that phone and a lone active reading on a
        // second one. There is no in-app signal for that; the release gate is the fix.
        elapsedCaption = (elapsed == active) ? nil : "\(elapsed) elapsed"
        activeAccessibilityLabel = elapsedCaption == nil
            ? "Active time, \(active)."
            : "Active time, \(active). Elapsed, \(elapsed)."
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path AuraCore --filter RideSummaryStatsTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --strict
git add AuraCore/Sources/AuraKit/Formatting/RideSummaryStats.swift AuraCore/Tests/AuraKitTests/RideSummaryStatsTests.swift
git commit -m "feat(roh-112): add RideSummaryStats, the summary stat row as strings"
```

---

### Task 4: Project the stats into `RideSummaryView`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift` (add an identifier above `summaryMoving`, currently `:33`)
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:45` (remove `metric`), `:278-282` (the cells)

**Interfaces:**
- Consumes: `RideSummaryStats` (Task 3), `Ride.duration` (Task 1).
- Produces: `RideTestID.summaryActive == "summary.active"`, read by Task 6.

- [ ] **Step 1: Add the test identifier**

In `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift`, directly above the existing
`summaryMoving` declaration and its doc comment, add:

```swift
    /// The summary's active-time cell. It is one combined element with an explicit label, so the
    /// label carries both numbers when the ride was paused: "Active time, 38 min. Elapsed, 48 min."
    public static let summaryActive = "summary.active"
```

- [ ] **Step 2: Replace the supporting cells**

In `Aura/Sources/Ride/RideSummaryView.swift`, replace `supportingCells`:

```swift
    @ViewBuilder private var supportingCells: some View {
        stat(fmt.minutes(stats.movingTimeSeconds), "moving", id: RideTestID.summaryMoving)
        stat(fmt.speedValue(stats.maxSpeedMetersPerSecond, decimals: 1),
             metric ? "km/h top" : "mph top")
    }
```

with:

```swift
    /// Pure string formatting only — `ViewThatFits` measures its candidates, so this is built more
    /// than once per body pass and must stay cheap. That is why `RideSummaryStats` takes scalars
    /// and never touches the track.
    @ViewBuilder private var supportingCells: some View {
        let summary = RideSummaryStats(duration: ride.duration,
                                       movingTimeSeconds: stats.movingTimeSeconds,
                                       maxSpeedMetersPerSecond: stats.maxSpeedMetersPerSecond,
                                       units: settings.units)
        activeCell(summary)
        stat(summary.movingValue, "moving", id: RideTestID.summaryMoving)
        stat(summary.topSpeedValue, summary.topSpeedLabel)
    }

    /// Active time, with elapsed as a subordinate caption rather than a fourth peer cell — the
    /// rider watched active on the HUD, and elapsed only explains the gap when there is one. The
    /// caption is absent on an unpaused ride, where it would repeat the value above it.
    private func activeCell(_ summary: RideSummaryStats) -> some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            StatPair(value: summary.activeValue, label: "active",
                     context: .brand, alignment: .leading)
            if let caption = summary.elapsedCaption {
                // Contrast-aware, unlike `StatPair`'s own label: this line is the smallest text
                // in the cell, so it is the first thing Increase Contrast needs to help with.
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(AuraTheme.secondaryText(contrast))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.activeAccessibilityLabel)
        .accessibilityIdentifier(RideTestID.summaryActive)
    }
```

The caption's leading spacing is `AuraTheme.Spacing.xs`, matching `StatPair`'s own value-to-label
gap (`StatPair.swift:23`). A tighter gap would bind the caption to the label more strongly than
the label binds to the number it describes.

- [ ] **Step 3: Remove the now-unused `metric`**

`metric` (line 45) had exactly one reader, the top-speed label that moved into `RideSummaryStats`.
Delete the line:

```swift
    private var metric: Bool { settings.units == .metric }
```

Verify with `grep -n "metric\b" Aura/Sources/Ride/RideSummaryView.swift` that the only remaining
hits are `metricBrand` and the word "metric" inside comments. `fmt` stays: `heroDistance` uses it.

- [ ] **Step 4: Build the app target**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an
iPhone simulator and report only pass/fail plus any error.
Expected: build succeeds.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --strict
git add AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(roh-112): lead the ride summary with active time"
```

---

### Task 5: The Dynamic Island's running clock says ACTIVE

**Files:**
- Modify: `Aura/Widgets/RideLiveActivity.swift:107`

**Interfaces:** none consumed or produced.

`RideLiveActivity.swift:107` sits inside `expandedTrailing(_:nav:imminent:clock:)`, a
`DynamicIslandExpandedRegion(.trailing)`, on the non-navigate branch. So the string appears in the
**expanded Dynamic Island of a running free ride** and nowhere else. The clock it labels is a
`RideActiveClock`, which is active time.

*(Revision 2: revision 1 called this the Lock Screen. It is not. `RideLockScreenView.swift:49`
and `:93` label their clock `TIME` and always have. A paused clock renders `PAUSED` via
`rideActivityClockLabel`, so the running label never appears on a paused ride either.)*

- [ ] **Step 1: Change the string**

In `Aura/Widgets/RideLiveActivity.swift`, line 107:

```swift
                Text(rideActivityClockLabel(clock, running: "ELAPSED"))
```

becomes:

```swift
                Text(rideActivityClockLabel(clock, running: "ACTIVE"))
```

Do not touch the `TIME` labels at `:128`, in `RideLockScreenView.swift`, or in
`RideActivityComponents.swift` — those are already neutral and correct.

- [ ] **Step 2: Confirm nothing asserted the old string**

Run: `grep -rn "ELAPSED" --include="*.swift" . | grep -v "\.build"`
Expected: no output. (It was the only occurrence in the repo before this change.)

- [ ] **Step 3: Build the widget extension**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme (which
builds `AuraWidgets`) for an iPhone simulator.
Expected: build succeeds.

- [ ] **Step 4: Lint and commit**

```bash
swiftlint --strict
git add Aura/Widgets/RideLiveActivity.swift
git commit -m "fix(roh-112): the Dynamic Island clock is active time, so label it ACTIVE"
```

---

### Task 6: E2E — the active cell is not the moving number

**Files:**
- Modify: `Aura/UITests/Screens/Screens.swift` (add an accessor beside `movingStat`, currently `:123`)
- Modify: `Aura/UITests/RideE2EUITests.swift` — call sites at `:276` and `:310`, new helper beside `assertMovingTimeIsSegmented` at `:340`
- Modify (temporarily, Step 4 only): `Aura/Sources/Ride/RideSummaryView.swift`

**Interfaces:**
- Consumes: `RideTestID.summaryActive` (Task 4), the `activeCell(_:)` helper and `supportingCells` binding from Task 4, and the existing `leadingNumber(in:)` helper at `RideE2EUITests.swift:413`.

- [ ] **Step 1: Add the screen accessor**

In `Aura/UITests/Screens/Screens.swift`, inside `SummaryScreen`, directly above `movingStat`:

```swift
    var activeStat: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.summaryActive).firstMatch
    }
```

- [ ] **Step 2: Write the assertion**

In `Aura/UITests/RideE2EUITests.swift`, directly above `assertMovingTimeIsSegmented`, add:

```swift
    /// The summary's active cell is fed the ride's own timestamps, not `movingTimeSeconds`.
    ///
    /// **Falsifiable because the two are measured on different clocks here.** Moving time is
    /// frozen at `PausedGoldenRideFixture.expectedMovingTimeSeconds` (290 s, from the GPX stamps)
    /// and renders "4 min". Active time is real wall clock — only the *location* stream replays
    /// at 20x — so the ~890 s fixture plays in ~45 s, minus the three pause dwells, and the cell
    /// renders "0 min" or "1 min". A cell still wired to `movingTimeSeconds` reads 4 in both and
    /// fails.
    ///
    /// **What it does NOT prove.** It cannot tell active from elapsed. Their difference here is
    /// the tester's dwell, a handful of seconds, and whole-minute truncation renders both as
    /// "0 min" — which is also why the elapsed caption is absent on this run and cannot be
    /// asserted. `RideDurationTests` and `RideSummaryStatsTests` cover the subtraction.
    ///
    /// Note for anyone reading a screenshot of this run: moving time EXCEEDS active time on this
    /// fixture, inverting the production invariant `moving ≤ active ≤ elapsed`, for the same
    /// two-clocks reason. That is the harness, not a defect.
    @MainActor
    private static func assertActiveIsNotTheMovingNumber(_ summary: SummaryScreen,
                                                         file: StaticString = #filePath,
                                                         line: UInt = #line) throws {
        // No swipe here: `assertMovingTimeIsSegmented` runs first and may already have scrolled,
        // and the active cell sits ABOVE the moving cell in both `ViewThatFits` candidates, so a
        // second swipe would scroll away from it. The ScrollView's VStack is eager, so the
        // element is in the tree either way.
        XCTAssertTrue(summary.activeStat.waitForExistence(timeout: 5), "active cell missing",
                      file: file, line: line)
        let activeLabel = summary.activeStat.label
        let movingLabel = summary.movingStat.label
        let active = try XCTUnwrap(leadingNumber(in: activeLabel),
                                   "no number in active label: \(activeLabel)",
                                   file: file, line: line)
        let moving = try XCTUnwrap(leadingNumber(in: movingLabel),
                                   "no number in moving label: \(movingLabel)",
                                   file: file, line: line)
        XCTAssertNotEqual(active, moving,
                          "active reads \(activeLabel), moving reads \(movingLabel). Either the "
                          + "active cell is being handed movingTimeSeconds, or playback stretched "
                          + "~5x under CI load and active genuinely reached \(moving) min — "
                          + "check the run duration before assuming the former.",
                          file: file, line: line)
    }
```

Then add the call at both existing summary-read sites, immediately after each
`try Self.assertMovingTimeIsSegmented(summary)` (currently lines 276 and 310 — the ride-end summary
and the History-detail re-read):

```swift
        try Self.assertActiveIsNotTheMovingNumber(summary)
```

- [ ] **Step 3: Run the paused golden ride**

Delegate to the `apple-platform-build-tools:builder` subagent: run the `AuraUITests` target's
paused golden-ride test on an iPhone 17 simulator.
Expected: PASS.

- [ ] **Step 4: Prove the assertion is load-bearing (negative control)**

Temporarily hand the active cell a duration whose active seconds equal moving time, which is what
a cell still wired to `movingTimeSeconds` renders. In `Aura/Sources/Ride/RideSummaryView.swift`,
replace the `activeCell(summary)` call in `supportingCells` with:

```swift
        activeCell(RideSummaryStats(
            duration: RideDuration(startedAt: ride.startedAt,
                                   endedAt: ride.startedAt.addingTimeInterval(stats.movingTimeSeconds),
                                   checkpointedAt: nil, pausedSeconds: 0),
            movingTimeSeconds: stats.movingTimeSeconds,
            maxSpeedMetersPerSecond: stats.maxSpeedMetersPerSecond,
            units: settings.units))
```

Re-run the paused golden ride and confirm `assertActiveIsNotTheMovingNumber` FAILS with the
"being handed movingTimeSeconds" message. **Revert the edit**, re-run, confirm PASS. Record both
observations in the commit message body, and confirm `git status` is clean before committing.

- [ ] **Step 5: Commit**

```bash
git add Aura/UITests/Screens/Screens.swift Aura/UITests/RideE2EUITests.swift
git commit -m "test(roh-112): assert the summary's active cell is not moving time"
```

---

## Verification before handoff

- [ ] `swift test --no-parallel --package-path AuraCore` — the swift-testing total is zero-failure. (The XCTest total reading `Executed 0 tests` is expected.)
- [ ] `bash scripts/check-single-active-definition.sh` — exit 0, no output.
- [ ] `swiftlint --strict` from the repo root — clean.
- [ ] App and widget build for an iPhone simulator (delegate to the builder subagent).
- [ ] `AuraUITests` paused golden ride passes, with the negative control observed and recorded.
- [ ] `git status` clean — no leftover negative-control edits.
- [ ] Whole-branch review on the most capable model, findings fixed.
- [ ] PR body names ROH-108 (the CloudKit **production** promotion of `CD_pausedSeconds`) as still owed: until it lands, a ride paused on one phone shows a lone active reading on a second synced device, with no in-app signal.

**Then stop.** The device pass is Rohun's:

1. **A paused ride on an iPhone SE**, at default, at one intermediate Dynamic Type size, and at AX5. The caption widens the first cell's ideal width, so a paused ride flips `ViewThatFits` to its vertical fallback at a *smaller* text size than an unpaused one — the intermediate size is where that flip lands, and it pushes the moving cell (a CI gate reads it) further down the scroll.
2. **The same ride unpaused**, confirming no elapsed caption appears and the row stays horizontal longer.
3. **The expanded Dynamic Island of a running free ride**, reading `ACTIVE`. Not the Lock Screen, which says `TIME`, and not while paused, which says `PAUSED`.
4. **A ride paused, then ended, with the Health toggle on**, if convenient: Fitness will report the wall-clock duration while Aura reports active. That mismatch is known and out of scope, but it is worth seeing once.
