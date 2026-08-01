# Active time on the ride summary (ROH-112) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The ride summary leads with active time (`elapsed - paused`), the number the rider watched on the HUD, with elapsed as a subordinate caption and the existing moving-time cell retained.

**Architecture:** One pure `RideDuration` type in AuraCore owns the finished ride's two durations and hosts the single definition of active time that the two existing live clocks are rewired to call. A pure `RideSummaryStats` in AuraKit resolves the summary's three stat cells to display strings from scalars, and `RideSummaryView` becomes a projection of it. One string changes in the Live Activity so "elapsed" stops naming two different numbers.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`) for package tests, XCTest/XCUITest for the E2E.

Spec: `docs/superpowers/specs/2026-08-01-roh112-active-time-design.md` (revision 2).

## Global Constraints

- **The moving cell is untouched.** `RideTestID.summaryMoving`, its label `"moving"`, and its value expression `fmt.minutes(stats.movingTimeSeconds)` must survive byte-identical. `RideE2EUITests.assertMovingTimeIsSegmented` is a CI gate that reads it.
- **`RideActiveClock.make` and `RideSessionCoordinator.refreshElapsed` change implementation, never behavior.** Their existing tests are the guard. Do not touch the clamping comments at `RideActiveClock.swift:44-52` — they document a Live Activity countdown bug.
- **Scope is the ride summary plus one Live Activity string.** The History caption, the Home last-ride card, the widget, and the share card stay on moving time (ROH-146). Do not edit `HistoryView.swift`, `LastRideCard.swift`, `LastRideWidget.swift`, `WidgetSnapshot.swift`, `ShareCardContent.swift`, or `ShareCardView.swift`.
- **Copy is exact:** cell label `active`, caption `"<N> min elapsed"`, Live Activity running label `ACTIVE`.
- **Package tests must pass on the macOS CI host**, so nothing in AuraCore/AuraKit may import SwiftUI, UIKit, or WidgetKit.
- Run package tests with `swift test --package-path AuraCore`. Note it prints **two** totals (one per test target); both must be zero-failure.
- Lint with `swiftlint --strict` run **from the repo root**.

---

## File Structure

| File | Responsibility |
| -- | -- |
| `AuraCore/Sources/AuraCore/Ride/RideDuration.swift` (create) | The finished ride's `elapsedSeconds`/`activeSeconds`, plus `activeSeconds(startedAt:asOf:pausedSeconds:)`, the one definition of active time. Also `Ride.duration` and `RideSummary.duration`. |
| `AuraCore/Tests/AuraCoreTests/RideDurationTests.swift` (create) | Task 1 coverage. |
| `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift` (modify) | Route through the shared primitive. |
| `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` (modify) | Route through the shared primitive. |
| `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift` (create) | The Live Activity clock and the finished ride's clock agree on the same inputs. |
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
- Consumes: `Ride` (`AuraCore/Sources/AuraCore/Models/Ride.swift`), `RideSummary` (`.../RideSummary.swift`). Both already have `startedAt: Date`, `endedAt: Date?`, `checkpointedAt: Date?`, and `pausedSeconds`.
- Produces:
  - `RideDuration.init?(startedAt: Date, endedAt: Date?, checkpointedAt: Date?, pausedSeconds: TimeInterval)`
  - `RideDuration.elapsedSeconds: TimeInterval`, `RideDuration.activeSeconds: TimeInterval`
  - `RideDuration.activeSeconds(startedAt: Date, asOf: Date, pausedSeconds: TimeInterval) -> TimeInterval` (static)
  - `Ride.duration: RideDuration?`, `RideSummary.duration: RideDuration?`

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

    @Test("A checkpointed ride has no duration at all")
    func checkpointedRideIsDisqualified() {
        // `RideRecorder.checkpoint(at:)` stamps endedAt at the PAUSE, so the interval it
        // describes can be a fraction of the ride the rider actually rode. Spec D2 disqualifies
        // it rather than reporting it under a badge the rider reads as "the last bit is missing".
        let end = start.addingTimeInterval(1800)
        #expect(RideDuration(startedAt: start, endedAt: end,
                             checkpointedAt: end, pausedSeconds: 0) == nil)
    }

    @Test("A ride with no end at all has no duration")
    func noEndMeansNoDuration() {
        // The legacy PR #90 dev-build rows: nil endedAt and no marker.
        #expect(RideDuration(startedAt: start, endedAt: nil,
                             checkpointedAt: nil, pausedSeconds: 0) == nil)
    }

    @Test("Paused time exceeding the ride clamps active to zero rather than going negative")
    func pausedLongerThanTheRideClampsToZero() throws {
        let d = try #require(RideDuration(startedAt: start,
                                          endedAt: start.addingTimeInterval(600),
                                          checkpointedAt: nil, pausedSeconds: 900))
        #expect(d.activeSeconds == 0)
        #expect(d.elapsedSeconds == 600)
    }

    @Test("The shared primitive is what every clock in the app subtracts with")
    func sharedPrimitiveSubtractsPausedTime() {
        let now = start.addingTimeInterval(1000)
        #expect(RideDuration.activeSeconds(startedAt: start, asOf: now,
                                           pausedSeconds: 250) == 750)
        #expect(RideDuration.activeSeconds(startedAt: start, asOf: now,
                                           pausedSeconds: 5000) == 0)
    }

    @Test("A Ride and its summary projection report the same duration")
    func rideAndSummaryAgree() throws {
        let end = start.addingTimeInterval(2880)
        let ride = Ride(kind: .freeRide, startedAt: start, endedAt: end, track: [],
                        stats: nil, pausedSeconds: 600, checkpointedAt: nil,
                        routeId: nil, destinationPlaceId: nil)
        let summary = RideSummary(id: ride.id, kind: .freeRide, startedAt: start, endedAt: end,
                                  hasStats: false, distanceMeters: 0, movingTimeSeconds: 0,
                                  pausedSeconds: 600, checkpointedAt: nil,
                                  elevationGainMeters: 0, destinationName: nil,
                                  thumbnailCoordinates: [])
        #expect(ride.duration == summary.duration)
        #expect(try #require(ride.duration).activeSeconds == 2280)
    }
}
```

There is deliberately **no test for `endedAt < startedAt`**. That path calls `assertionFailure`, which traps in a debug test build, so a test for it would abort the suite rather than pass.

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

    /// Nil for an unfinished ride, which is the only unavailable case.
    ///
    /// **`checkpointedAt` is read as a disqualifier, never as a clock.**
    /// `RideRecorder.checkpoint(at:)` stamps `endedAt` at the *pause*, so a rider who paused at
    /// minute 30, resumed, and was killed at minute 90 has a row whose `endedAt` is minute 30.
    /// Reporting "30 min" for that ride is confidently wrong in a way the unfinished badge does
    /// not cover — a rider reads that badge as "the last bit is missing", not "two thirds of this
    /// ride is missing" (spec D2). The moving cell still reports what was actually recorded.
    ///
    /// A nil `endedAt` with no marker is the legacy PR #90 dev-build row, also nil here.
    public init?(startedAt: Date, endedAt: Date?, checkpointedAt: Date?,
                 pausedSeconds: TimeInterval) {
        guard let endedAt, checkpointedAt == nil else { return nil }
        let elapsed = endedAt.timeIntervalSince(startedAt)
        if elapsed < 0 {
            // A degenerate recorder state, not a device clock: `checkpoint(at:)`'s
            // `startedAt ?? date` collapses to a zero interval when the recorder never started.
            // Loud in DEBUG and CI, non-fatal in release, exactly as `RideMigrationPlan` treats an
            // undecodable stats blob. A silent clamp is how a future auto-pause accounting bug
            // ships as "active time is a bit low" and never gets reported.
            assertionFailure("RideDuration: endedAt \(endedAt) precedes startedAt \(startedAt)")
        }
        elapsedSeconds = max(0, elapsed)
        activeSeconds = RideDuration.activeSeconds(startedAt: startedAt, asOf: endedAt,
                                                   pausedSeconds: pausedSeconds)
    }

    /// **The one definition of active time**: wall clock since the start, less time spent paused.
    ///
    /// Three clocks call this and nothing re-derives it — the HUD's live number
    /// (`RideSessionCoordinator.refreshElapsed`), the Live Activity's (`RideActiveClock.make`),
    /// and the finished ride's (`init` above). Parent spec D5 makes their agreement a product
    /// requirement: the rider must see the same clock after the ride that they watched during it.
    /// One function is what makes that an invariant instead of three subtractions that happen to
    /// match today.
    ///
    /// For a running ride `pausedSeconds` must be measured as of `now`, including a stop still
    /// open; see `RideActiveClock.make`.
    public static func activeSeconds(startedAt: Date, asOf now: Date,
                                     pausedSeconds: TimeInterval) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt) - pausedSeconds)
    }
}

extension Ride {
    /// This ride's durations, or nil when it is unfinished. See `RideDuration.init`.
    public var duration: RideDuration? {
        RideDuration(startedAt: startedAt, endedAt: endedAt,
                     checkpointedAt: checkpointedAt, pausedSeconds: pausedSeconds)
    }
}

extension RideSummary {
    /// This row's durations, or nil when the ride is unfinished. See `RideDuration.init`.
    public var duration: RideDuration? {
        RideDuration(startedAt: startedAt, endedAt: endedAt,
                     checkpointedAt: checkpointedAt, pausedSeconds: pausedSeconds)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path AuraCore --filter RideDurationTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --strict
git add AuraCore/Sources/AuraCore/Ride/RideDuration.swift AuraCore/Tests/AuraCoreTests/RideDurationTests.swift
git commit -m "feat(roh-112): add RideDuration, the one definition of active time"
```

---

### Task 2: Route the two live clocks through the shared primitive

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift:43`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:224`
- Test: `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift` (create)

**Interfaces:**
- Consumes: `RideDuration.activeSeconds(startedAt:asOf:pausedSeconds:)` from Task 1.
- Produces: no new API. Behavior is unchanged by construction.

This task is a refactor with two guards that make the refactor's *point* enforceable: a test for the Live Activity clock, and a grep for single-definition. `RideActiveClock.make` and `refreshElapsed` today both compute `max(0, now - startedAt - pausedSeconds)` in longhand. After this task there is one copy of that expression in the codebase.

`refreshElapsed` gets no direct test here. Its `startedAt` is private and set from `Date()` inside `start()`, so a test cannot supply the inputs needed to compare it against the primitive without reaching through the coordinator's whole lifecycle; its behavior is already pinned by `RideSessionCoordinatorPauseTests`. Step 5's grep is what keeps it on the shared definition. Do not claim more than that in a comment.

- [ ] **Step 1: Write the test**

Create `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

/// The Live Activity's clock and the finished ride's clock must report the same active time for
/// the same inputs. Parent spec D5 rests on it: the rider sees the number they watched when they
/// pressed End. Separately-written subtractions would agree today and drift on the first change
/// to either, so this pins the agreement rather than trusting a doc comment.
///
/// The HUD's own clock (`RideSessionCoordinator.refreshElapsed`) is the third caller and is not
/// tested here — its `startedAt` is private and stamped from `Date()`, so the inputs cannot be
/// supplied. It is held to the shared definition by review and by the single-definition grep in
/// the ROH-112 plan, and its behavior by `RideSessionCoordinatorPauseTests`.
@Suite("Active time agreement")
struct ActiveTimeAgreementTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("The Live Activity clock's active reading matches the shared primitive")
    func liveActivityClockMatchesPrimitive() {
        for (paused, offset) in [(0.0, 600.0), (240.0, 900.0), (5000.0, 600.0)] {
            let now = start.addingTimeInterval(offset)
            let expected = RideDuration.activeSeconds(startedAt: start, asOf: now,
                                                      pausedSeconds: paused)
            // A stop is open, so the clock carries its active reading explicitly.
            let clock = RideActiveClock.make(startedAt: start, pausedSeconds: paused,
                                             pausedSince: now, now: now)
            guard case .paused(_, let activeSeconds) = clock else {
                Issue.record("expected a paused clock for paused: \(paused)")
                continue
            }
            #expect(activeSeconds == expected)
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

- [ ] **Step 2: Run the test to verify it passes already, then confirm it is load-bearing**

Run: `swift test --package-path AuraCore --filter ActiveTimeAgreementTests`
Expected: PASS. The two implementations already agree; the test exists to keep them agreeing.

Now confirm the test can fail. Temporarily change `RideActiveClock.swift:43` to
`let activeSeconds = max(0, now.timeIntervalSince(startedAt) - pausedSeconds / 2)`, re-run, and
confirm `liveActivityClockMatchesPrimitive` FAILS. **Revert the edit before continuing.** Record
the observed failure in the commit message body.

- [ ] **Step 3: Rewire `RideActiveClock.make`**

In `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift`, replace line 43 only:

```swift
        let activeSeconds = max(0, now.timeIntervalSince(startedAt) - pausedSeconds)
```

with:

```swift
        let activeSeconds = RideDuration.activeSeconds(startedAt: startedAt, asOf: now,
                                                       pausedSeconds: pausedSeconds)
```

Leave every comment in that function unchanged, including the clamping note at lines 44-52.

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

- [ ] **Step 5: Verify there is exactly one definition left**

Run:

```bash
grep -rn "timeIntervalSince(startedAt) -" --include="*.swift" AuraCore/Sources Aura/Sources Aura/Widgets
```

Expected: exactly one hit, inside `RideDuration.activeSeconds`. Any other hit is a clock that
re-derives active time instead of calling the shared definition, which is the drift this task
exists to prevent.

- [ ] **Step 6: Run the full package suite**

Run: `swift test --package-path AuraCore`
Expected: PASS. `RideActiveClockTests` and `RideSessionCoordinatorPauseTests` are the guard that behavior did not move. Remember the run prints two totals; both must be zero-failure.

- [ ] **Step 7: Lint and commit**

```bash
swiftlint --strict
git add AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift \
        AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift \
        AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift
git commit -m "refactor(roh-112): route both live clocks through RideDuration.activeSeconds"
```

---

### Task 3: `RideSummaryStats`, the summary's stat row as display strings

**Files:**
- Create: `AuraCore/Sources/AuraKit/Formatting/RideSummaryStats.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSummaryStatsTests.swift`

**Interfaces:**
- Consumes: `RideDuration` (Task 1), `RideStatsFormatter` (`AuraKit/Formatting/RideStatsFormatter.swift`), `DistanceUnits`.
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

    @Test("An unfinished ride shows a dash and no caption")
    func unfinishedRideIsDashed() {
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
        #expect(stats(duration(elapsed: 2880, paused: 600), units: .metric).topSpeedLabel == "km/h top")
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
/// the branching is unit tested without the app target. `RideSummaryView`'s row is a dumb
/// projection of this.
///
/// **Takes scalars, never a `Ride`.** The view builds this inside `body`, and this project's rule
/// (see `RideSummaryView.swift:52`) is that nothing track-derived is read there. A type holding a
/// whole ride invites the next author to add one `flattenedPoints`-derived field and hand the
/// summary an O(n) walk on every body evaluation — which is exactly why `ShareCardContent`, the
/// other type of this shape, is built in a `.task` instead.
public struct RideSummaryStats: Equatable, Sendable {
    /// "38 min", or "—" when the ride is unfinished and has no computable duration.
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
        topSpeedLabel = units == .metric ? "km/h top" : "mph top"

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
- Modify: `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift:33` (add an identifier beside `summaryMoving`)
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:45` (remove `metric`), `:277-282` (the cells)

**Interfaces:**
- Consumes: `RideSummaryStats` (Task 3), `Ride.duration` (Task 1).
- Produces: `RideTestID.summaryActive == "summary.active"`, read by Task 6.

- [ ] **Step 1: Add the test identifier**

In `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift`, directly above the existing
`summaryMoving` declaration, add:

```swift
    /// The summary's active-time cell. Its accessibility label carries both numbers —
    /// "Active time, 38 min. Elapsed, 48 min." — because the cell is one combined element.
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
    @ViewBuilder private var supportingCells: some View {
        // Bound once rather than recomputed per cell: this is built during `body`.
        let summary = RideSummaryStats(duration: ride.duration,
                                       movingTimeSeconds: stats.movingTimeSeconds,
                                       maxSpeedMetersPerSecond: stats.maxSpeedMetersPerSecond,
                                       units: settings.units)
        activeCell(summary)
        stat(summary.movingValue, "moving", id: RideTestID.summaryMoving)
        stat(summary.topSpeedValue, summary.topSpeedLabel)
    }

    /// Active time, with elapsed as a subordinate caption rather than a fourth peer cell — the
    /// rider watched active on the HUD, and elapsed only explains the gap when there is one.
    /// The caption is absent on an unpaused ride, where it would repeat the value above it.
    private func activeCell(_ summary: RideSummaryStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            StatPair(value: summary.activeValue, label: "active",
                     context: .brand, alignment: .leading)
            if let caption = summary.elapsedCaption {
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

- [ ] **Step 3: Remove the now-unused `metric`**

`metric` (line 45) had exactly one reader, the top-speed label that moved into `RideSummaryStats`.
Delete the line:

```swift
    private var metric: Bool { settings.units == .metric }
```

Verify with `grep -n "metric\b" Aura/Sources/Ride/RideSummaryView.swift` that the only remaining
hits are `metricBrand` and the words "metric" inside comments. `fmt` stays: `heroDistance` uses it.

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

### Task 5: The Live Activity's running clock says ACTIVE

**Files:**
- Modify: `Aura/Widgets/RideLiveActivity.swift:107`

**Interfaces:** none consumed or produced.

The clock at that site is a `RideActiveClock`, which is active time, and it is labeled `ELAPSED`.
Shipping Task 4 without this leaves "elapsed" naming active time on the Lock Screen and wall clock
on the summary the rider lands on seconds later.

- [ ] **Step 1: Change the string**

In `Aura/Widgets/RideLiveActivity.swift`, line 107:

```swift
                Text(rideActivityClockLabel(clock, running: "ELAPSED"))
```

becomes:

```swift
                Text(rideActivityClockLabel(clock, running: "ACTIVE"))
```

Do not touch the `TIME` labels at `:128` and in `RideActivityComponents.swift` — those are already
neutral and correct.

- [ ] **Step 2: Confirm nothing asserted the old string**

Run: `grep -rn "ELAPSED" --include="*.swift" . | grep -v "\.build"`
Expected: no output. (It was the only occurrence in the repo before this change.)

- [ ] **Step 3: Build the widget extension**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme (which
builds `AuraWidgets`) for an iPhone simulator.
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Aura/Widgets/RideLiveActivity.swift
git commit -m "fix(roh-112): the Live Activity clock is active time, so label it ACTIVE"
```

---

### Task 6: E2E — the active cell is not the moving number

**Files:**
- Modify: `Aura/UITests/Screens/Screens.swift:123` (add an accessor beside `movingStat`)
- Modify: `Aura/UITests/RideE2EUITests.swift:275-276` and `:309-310` (call sites), plus a new helper beside `assertMovingTimeIsSegmented` at `:340`

**Interfaces:**
- Consumes: `RideTestID.summaryActive` (Task 4), the existing `leadingNumber(in:)` helper at `RideE2EUITests.swift:413`.

- [ ] **Step 1: Add the screen accessor**

In `Aura/UITests/Screens/Screens.swift`, inside `SummaryScreen`, directly above `movingStat`:

```swift
    var activeStat: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.summaryActive).firstMatch
    }
```

- [ ] **Step 2: Write the failing assertion**

In `Aura/UITests/RideE2EUITests.swift`, directly above `assertMovingTimeIsSegmented`, add:

```swift
    /// The summary's active cell is fed the ride's own timestamps, not `movingTimeSeconds`.
    ///
    /// Falsifiable on this fixture precisely because the two numbers are measured on different
    /// clocks: moving time is frozen at `PausedGoldenRideFixture.expectedMovingTimeSeconds`
    /// (290 s, from the GPX stamps) and renders "4 min", while active time is wall clock over a
    /// ~45 s playback at 20x plus the tester's dwell at the three pauses. A surface still handed
    /// `movingTimeSeconds` reads 4 in both cells and fails here.
    ///
    /// What it does NOT prove: that paused time was subtracted. The gap between active and
    /// elapsed here is the tester's real dwell, a handful of seconds, which whole-minute
    /// formatting usually cannot resolve. `RideDurationTests` and `RideSummaryStatsTests` cover
    /// the subtraction.
    ///
    /// Note for anyone reading a screenshot of this run: moving time EXCEEDS active time on this
    /// fixture, inverting the production invariant `moving ≤ active ≤ elapsed`, for the same
    /// two-clocks reason. That is the harness, not a defect.
    @MainActor
    private static func assertActiveIsNotTheMovingNumber(_ summary: SummaryScreen,
                                                         file: StaticString = #filePath,
                                                         line: UInt = #line) throws {
        if !summary.activeStat.waitForExistence(timeout: 5) { summary.app.swipeUp() }
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
                          "active reads \(activeLabel) and moving reads \(movingLabel) — the "
                          + "active cell is being handed movingTimeSeconds",
                          file: file, line: line)
    }
```

Then add the call at both existing summary-read sites, immediately after each
`try Self.assertMovingTimeIsSegmented(summary)` (currently lines 276 and 310):

```swift
        try Self.assertActiveIsNotTheMovingNumber(summary)
```

- [ ] **Step 3: Run the paused golden ride**

Delegate to the `apple-platform-build-tools:builder` subagent: run the `AuraUITests` target's
paused golden-ride test on an iPhone 17 simulator.
Expected: PASS.

- [ ] **Step 4: Prove the assertion is load-bearing (negative control)**

Temporarily hand the active cell a duration whose active seconds equal moving time, which is what
a surface still wired to `movingTimeSeconds` would render. In `supportingCells`, replace the
`activeCell(summary)` call with:

```swift
        let neutered = RideSummaryStats(
            duration: RideDuration(startedAt: ride.startedAt,
                                   endedAt: ride.startedAt.addingTimeInterval(stats.movingTimeSeconds),
                                   checkpointedAt: nil, pausedSeconds: 0),
            movingTimeSeconds: stats.movingTimeSeconds,
            maxSpeedMetersPerSecond: stats.maxSpeedMetersPerSecond,
            units: settings.units)
        activeCell(neutered)
```

Re-run the paused golden ride and confirm `assertActiveIsNotTheMovingNumber` FAILS with the
"being handed movingTimeSeconds" message. **Revert the edit**, re-run, confirm PASS. Record both
observations in the commit message body.

- [ ] **Step 5: Commit**

```bash
git add Aura/UITests/Screens/Screens.swift Aura/UITests/RideE2EUITests.swift
git commit -m "test(roh-112): assert the summary's active cell is not moving time"
```

---

## Verification before handoff

- [ ] `swift test --package-path AuraCore` — both target totals zero-failure.
- [ ] `swiftlint --strict` from the repo root — clean.
- [ ] App and widget build for an iPhone simulator (delegate to the builder subagent).
- [ ] `AuraUITests` paused golden ride passes, with the negative control observed and recorded.
- [ ] Whole-branch review on the most capable model, findings fixed.
- [ ] Note in the PR body that ROH-108 (the CloudKit **production** schema promotion covering `CD_pausedSeconds`) is still owed. Until it lands, a ride paused on one phone renders active equal to elapsed on a second synced device, silently.
- [ ] **Stop.** The device pass is Rohun's: summary on an iPhone SE at default and AX5 text sizes, a paused ride showing `ACTIVE` on the Lock Screen and the pair on the summary, and an unpaused ride showing no elapsed caption.
