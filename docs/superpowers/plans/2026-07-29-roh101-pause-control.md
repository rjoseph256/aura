# ROH-101 Pass 4: cockpit pause control implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the rider a pause/resume control on both ride HUDs, a paused state readable on four surfaces, confirmation haptics, and a bounded local-notification ladder that rescues a forgotten resume.

**Architecture:** Pass 2 already owns the ride logic (`RideSessionCoordinator.pause()`/`resume()`); this pass adds only the rider-facing layer. Pure values (nudge policy, control copy, ribbon styling) live in AuraCore so they unit-test on the macOS host. Side effects (haptics, notifications) hang off coordinator-owned seams with **required** constructor parameters, so a half-wired HUD is a compile error rather than a feature that ships dead on one screen. The app target holds only conformers and views.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, MapboxMaps v11, UserNotifications (new to this app), Swift Testing + XCTest.

**Spec:** [2026-07-29-roh101-pause-control-design.md](../specs/2026-07-29-roh101-pause-control-design.md) (revision 2). Parent: [2026-07-26-segmented-rides-pause-design.md](../specs/2026-07-26-segmented-rides-pause-design.md) D9. Also discharges three obligations assigned to this pass by [ROH-105's D5](../specs/2026-07-27-roh105-dead-peer-split-deletion-design.md).

## Global Constraints

- **SwiftLint must be run from the repo root.** It fails when run from a subdirectory.
- **Never use `AuraTheme.warning` / amber for paused.** Amber carries peer-stopped and weak/lost GPS. Paused uses mint for the action and neutral text for the state.
- **The paused "held" treatment uses `AuraTheme.textSecondary`, never an opacity multiplier on `textPrimary`.** Only the former is contrast-guarded by `AuraPaletteContrastTests`.
- **Do not add an accessible child inside `InstrumentChassis`.** Its one-composed-VoiceOver-element invariant is a comment, not a test.
- **`TrackRibbon` must keep emitting exactly one piece per segment.** `RideMapView` keys its Mapbox annotation group on `sourceIndex`; duplicates collide silently.
- **New pure types go in AuraCore or AuraKit, never the app target.** The app target has no unit test target (`Aura/project.yml:123-124`).
- **Test doubles must never construct a real `LocationService`.** Use the existing `FakeLocationManager` seam (ROH-88).
- **No async default-argument closures anywhere** (banned repo-wide; SwiftLint guards it).
- Package suite: `swift test --package-path AuraCore --no-parallel` from the repo root. It prints **two** totals, one per test target. Both must be clean.
- App build: `xcodegen generate` from `Aura/`, then `xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17'`.

---

### Task 1: `TrackRibbon` paused styling discriminator

Discharges ROH-105 D5's "reintroduce a pure discriminator rather than grow the ternary".

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Geo/TrackRibbon.swift`
- Test: `AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `TrackRibbon.Piece.Style` (`.recorded` / `.paused`), `Piece.style: Style`, and `TrackRibbon.pieces(segments:isPaused:) -> [Piece]` with `isPaused` defaulting to `false`.

- [ ] **Step 1: Write the failing tests**

Append to `AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift`:

```swift
@Test("An unpaused ride styles every piece as recorded")
func recordedWhenNotPaused() {
    let segments = [RideSegment(points: [pt(0, 0), pt(0, 1)]),
                    RideSegment(points: [pt(1, 0), pt(1, 1)])]
    let pieces = TrackRibbon.pieces(segments: segments, isPaused: false)
    #expect(pieces.map(\.style) == [.recorded, .recorded])
}

@Test("A paused ride styles only the trailing piece as paused")
func pausedStylesTrailingPieceOnly() {
    let segments = [RideSegment(points: [pt(0, 0), pt(0, 1)]),
                    RideSegment(points: [pt(1, 0), pt(1, 1)])]
    let pieces = TrackRibbon.pieces(segments: segments, isPaused: true)
    #expect(pieces.map(\.style) == [.recorded, .paused])
}

@Test("The paused style follows the last drawn piece, not the last segment")
func pausedFollowsLastDrawnPiece() {
    // A trailing segment with a single point strokes nothing and is dropped, so the
    // paused style must land on the piece that is actually drawn last.
    let segments = [RideSegment(points: [pt(0, 0), pt(0, 1)]),
                    RideSegment(points: [pt(1, 0)])]
    let pieces = TrackRibbon.pieces(segments: segments, isPaused: true)
    #expect(pieces.count == 1)
    #expect(pieces[0].style == .paused)
    #expect(pieces[0].sourceIndex == 0)
}

@Test("Paused styling never duplicates a sourceIndex")
func pausedKeepsSourceIndicesUnique() {
    let segments = (0..<4).map { i in RideSegment(points: [pt(Double(i), 0), pt(Double(i), 1)]) }
    let indices = TrackRibbon.pieces(segments: segments, isPaused: true).map(\.sourceIndex)
    #expect(Set(indices).count == indices.count)
}

@Test("An empty ride yields no pieces even when paused")
func emptyPausedRideYieldsNothing() {
    #expect(TrackRibbon.pieces(segments: [], isPaused: true).isEmpty)
}
```

If `pt(_:_:)` does not already exist in this test file, add this helper at file scope. Note the
label is `elevation:`, not `elevationMeters:`:

```swift
private func pt(_ lat: Double, _ lon: Double) -> TrackPoint {
    TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
               elevation: 250, timestamp: Date(timeIntervalSince1970: 0),
               speedMetersPerSecond: nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path AuraCore --no-parallel --filter TrackRibbon`
Expected: compile failure, `extra argument 'isPaused' in call` and `value of type 'Piece' has no member 'style'`.

- [ ] **Step 3: Implement**

In `TrackRibbon.Piece`, add above `sourceIndex`:

```swift
        /// How this piece should be stroked. `.paused` marks the run the rider is stopped in
        /// (ROH-101): the map itself says recording has stopped, so the paused state does not
        /// depend on the rider looking at the cockpit.
        ///
        /// Deliberately a value on the piece rather than a term in `RideMapView`'s stroke
        /// ternary: that expression lives in the app target, which has no unit test target,
        /// and this is the pass's headline visual (ROH-105 D5).
        public let style: Style

        public enum Style: Equatable, Sendable {
            /// A closed segment, or any segment of a ride that is recording.
            case recorded
            /// The run the rider paused in. At most one piece per ribbon.
            case paused
        }
```

Replace the initializer, keeping the old arity working for existing callers:

```swift
        public init(coordinates: [Coordinate], sourceIndex: Int, style: Style = .recorded) {
            self.coordinates = coordinates
            self.sourceIndex = sourceIndex
            self.style = style
        }
```

Replace `pieces(segments:)`:

```swift
    /// - Parameter isPaused: whether the ride is stopped right now. When true the **last
    ///   drawn** piece is styled `.paused` — the last drawn one, not the last segment, because
    ///   a trailing single-point segment strokes nothing and is dropped.
    /// - Returns: drawable pieces in ride order, one per segment. Runs of fewer than two
    ///   coordinates are dropped — a single point strokes nothing — without shifting the
    ///   `sourceIndex` of the runs after them.
    public static func pieces(segments: [RideSegment], isPaused: Bool = false) -> [Piece] {
        var pieces = segments.enumerated().compactMap { index, segment -> Piece? in
            let run = segment.points.map(\.coordinate)
            guard run.count > 1 else { return nil }   // strokes nothing
            return Piece(coordinates: run, sourceIndex: index)
        }
        if isPaused, let last = pieces.indices.last {
            pieces[last] = Piece(coordinates: pieces[last].coordinates,
                                 sourceIndex: pieces[last].sourceIndex,
                                 style: .paused)
        }
        return pieces
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path AuraCore --no-parallel --filter TrackRibbon`
Expected: PASS, including the pre-existing `test_sourceIndicesAreUnique`.

- [ ] **Step 5: Update the type's doc comment, which now names an unfulfilled obligation**

In the `sourceIndex` doc comment, replace the sentence beginning "A future rule that emits more than one piece per segment (Pass 4 / ROH-101 renders the current segment differently while paused) must introduce a compound key" with:

```swift
        /// ROH-101 renders the paused run differently, and does it with `style` rather than by
        /// emitting a second piece, precisely so this stays one piece per segment. A future rule
        /// that does split a segment must introduce a compound key.
        /// `TrackRibbonTests.test_sourceIndicesAreUnique` documents the invariant, and
        /// `pausedKeepsSourceIndicesUnique` now covers the paused case its fixture could not.
```

- [ ] **Step 6: Lint and commit**

```bash
swiftlint lint --strict
git add AuraCore/Sources/AuraCore/Geo/TrackRibbon.swift AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift
git commit -m "feat(roh-101): style the paused run in TrackRibbon"
```

---

### Task 2: `PauseNudgePolicy`

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/PauseNudgePolicy.swift`
- Test: `AuraCore/Tests/AuraCoreTests/PauseNudgePolicyTests.swift`

**Interfaces:**
- Produces: `PauseNudgePolicy.rungs: [Rung]`, `Rung.after: TimeInterval`, `Rung.identifier: String`, `Rung.title: String`, `Rung.body: String`, and `PauseNudgePolicy.allIdentifiers: [String]`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/PauseNudgePolicyTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("Pause nudge policy")
struct PauseNudgePolicyTests {
    @Test("The ladder backs off rather than repeating at a fixed interval")
    func ladderBacksOff() {
        let offsets = PauseNudgePolicy.rungs.map(\.after)
        #expect(offsets == [600, 1500, 2700, 4500, 7200])
    }

    @Test("The ladder is strictly increasing")
    func strictlyIncreasing() {
        let offsets = PauseNudgePolicy.rungs.map(\.after)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("Every rung clears the 60 second floor a time-interval trigger requires")
    func clearsTriggerFloor() {
        #expect(PauseNudgePolicy.rungs.allSatisfy { $0.after >= 60 })
    }

    @Test("Identifiers are unique, so cancellation removes every rung")
    func identifiersAreUnique() {
        let ids = PauseNudgePolicy.allIdentifiers
        #expect(ids.count == PauseNudgePolicy.rungs.count)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Each rung states its own duration, which a repeating trigger could not")
    func bodyStatesTheDuration() {
        #expect(PauseNudgePolicy.rungs[0].body.contains("10 minutes"))
        #expect(PauseNudgePolicy.rungs[1].body.contains("25 minutes"))
        #expect(PauseNudgePolicy.rungs[4].body.contains("2 hours"))
    }

    @Test("No rung claims the ride is still recording")
    func copyIsHonest() {
        #expect(PauseNudgePolicy.rungs.allSatisfy { $0.body.contains("isn't recording") })
    }

    @Test("The ladder is bounded, so a jetsam orphan cannot nag forever")
    func ladderIsBounded() {
        #expect(PauseNudgePolicy.rungs.count == 5)
        #expect(PauseNudgePolicy.rungs.last?.after == 7200)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path AuraCore --no-parallel --filter PauseNudgePolicy`
Expected: FAIL, `cannot find 'PauseNudgePolicy' in scope`.

- [ ] **Step 3: Implement**

Create `AuraCore/Sources/AuraCore/Ride/PauseNudgePolicy.swift`:

```swift
import Foundation

/// When to nudge a rider who paused and never resumed, and what to say.
///
/// **A bounded ladder, not a repeating trigger.** A repeating notification cannot rewrite its
/// own body, so it can never say how long the stop has been; it nags a deliberate two-hour
/// lunch a dozen times; and because a long pause is exactly the condition that invites a
/// jetsam kill (spec D7), an orphaned repeat fires every ten minutes forever at a rider who is
/// not going to open the app. Five one-shot rungs fix all three: each states its own duration,
/// the gaps widen as the stop starts to look deliberate, and the worst an orphan can do is five
/// notifications ending two hours after the pause.
///
/// Plain values with no UserNotifications import, so the schedule is unit-tested on the macOS
/// host and the app target holds only the conformer that posts them.
public enum PauseNudgePolicy {
    public struct Rung: Equatable, Sendable {
        /// Seconds after the pause began.
        public let after: TimeInterval
        /// Stable request identifier, so cancellation removes exactly these.
        public let identifier: String
        public let title: String
        public let body: String

        public init(after: TimeInterval, identifier: String, title: String, body: String) {
            self.after = after
            self.identifier = identifier
            self.title = title
            self.body = body
        }
    }

    /// 10, 25, 45, 75 and 120 minutes. Ten minutes clears a coffee queue, a mechanical or a
    /// photo stop without firing; the widening gaps stop punishing a rider who paused on purpose.
    public static let rungs: [Rung] = [
        Rung(after: 600, identifier: "pause.nudge.1", title: "Ride still paused",
             body: "Your ride has been paused for 10 minutes and isn't recording."),
        Rung(after: 1500, identifier: "pause.nudge.2", title: "Ride still paused",
             body: "Your ride has been paused for 25 minutes and isn't recording."),
        Rung(after: 2700, identifier: "pause.nudge.3", title: "Ride still paused",
             body: "Your ride has been paused for 45 minutes and isn't recording."),
        Rung(after: 4500, identifier: "pause.nudge.4", title: "Ride still paused",
             body: "Your ride has been paused for 75 minutes and isn't recording."),
        Rung(after: 7200, identifier: "pause.nudge.5", title: "Ride still paused",
             body: "Your ride has been paused for 2 hours and isn't recording.")
    ]

    public static var allIdentifiers: [String] { rungs.map(\.identifier) }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path AuraCore --no-parallel --filter PauseNudgePolicy`
Expected: PASS (7 tests).

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --strict
git add AuraCore/Sources/AuraCore/Ride/PauseNudgePolicy.swift AuraCore/Tests/AuraCoreTests/PauseNudgePolicyTests.swift
git commit -m "feat(roh-101): bounded pause-nudge ladder as pure policy"
```

---

### Task 3: `PauseControlCopy` and the two test identifiers

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/PauseControlCopy.swift`
- Modify: `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift`
- Test: `AuraCore/Tests/AuraCoreTests/PauseControlCopyTests.swift`

**Interfaces:**
- Produces: `PauseControlCopy.buttonLabel(isPaused:)`, `.accessibilityLabel(isPaused:)`, `.announcement(isPaused:)`, `.stateChipLabel`, `.chipAccessibilityLabel(pausedSeconds:)`, `.clock(_:)`; and `RideTestID.hudPause`, `RideTestID.hudPausedBanner`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/PauseControlCopyTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("Pause control copy")
struct PauseControlCopyTests {
    @Test("The visible label names the action, not the state")
    func buttonLabelNamesTheAction() {
        #expect(PauseControlCopy.buttonLabel(isPaused: false) == "Pause")
        #expect(PauseControlCopy.buttonLabel(isPaused: true) == "Resume")
    }

    @Test("The VoiceOver label tracks state rather than using a toggle value")
    func accessibilityLabelTracksState() {
        // "Pause ride, on" would be ambiguous about whether "on" describes the pause
        // or the ride, so the label itself changes.
        #expect(PauseControlCopy.accessibilityLabel(isPaused: false) == "Pause ride")
        #expect(PauseControlCopy.accessibilityLabel(isPaused: true) == "Resume ride")
    }

    @Test("The transition announcement states the new state in the past tense")
    func announcementStatesTheNewState() {
        #expect(PauseControlCopy.announcement(isPaused: true) == "Ride paused")
        #expect(PauseControlCopy.announcement(isPaused: false) == "Ride resumed")
    }

    @Test("The chip label is a single uppercase word")
    func chipLabel() {
        #expect(PauseControlCopy.stateChipLabel == "PAUSED")
    }

    @Test("The clock renders minutes and seconds under an hour")
    func clockUnderAnHour() {
        #expect(PauseControlCopy.clock(0) == "0:00")
        #expect(PauseControlCopy.clock(9) == "0:09")
        #expect(PauseControlCopy.clock(252) == "4:12")
        #expect(PauseControlCopy.clock(3599) == "59:59")
    }

    @Test("The clock grows an hours field rather than running minutes past 59")
    func clockOverAnHour() {
        #expect(PauseControlCopy.clock(3600) == "1:00:00")
        #expect(PauseControlCopy.clock(7565) == "2:06:05")
    }

    @Test("A negative interval cannot render a negative clock")
    func clockClampsNegative() {
        #expect(PauseControlCopy.clock(-5) == "0:00")
    }

    @Test("The chip's VoiceOver read spells the duration out in words")
    func chipAccessibilityLabel() {
        #expect(PauseControlCopy.chipAccessibilityLabel(pausedSeconds: 252)
                == "Paused for 4 minutes 12 seconds")
        #expect(PauseControlCopy.chipAccessibilityLabel(pausedSeconds: 45)
                == "Paused for 45 seconds")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path AuraCore --no-parallel --filter PauseControlCopy`
Expected: FAIL, `cannot find 'PauseControlCopy' in scope`.

- [ ] **Step 3: Implement the copy**

Create `AuraCore/Sources/AuraCore/Ride/PauseControlCopy.swift`:

```swift
import Foundation

/// Every string the pause control and its state chip render, as plain values so they are
/// unit-tested on the host rather than eyeballed in a SwiftUI preview.
///
/// The clock is deliberately its own function rather than a `Duration.formatted` call: the chip
/// sits beside a Saira cockpit numeral at 56 pt of row height, and a localized "4 min 12 sec"
/// would wrap where "4:12" does not.
public enum PauseControlCopy {
    /// The word on the control.
    public static func buttonLabel(isPaused: Bool) -> String {
        isPaused ? "Resume" : "Pause"
    }

    /// The VoiceOver label. Changes with state instead of pairing a fixed label with a toggle
    /// value, because "Pause ride, on" does not say whether "on" is the pause or the ride.
    public static func accessibilityLabel(isPaused: Bool) -> String {
        isPaused ? "Resume ride" : "Pause ride"
    }

    /// Posted after the state changes, so a VoiceOver rider learns it landed without having to
    /// re-read the control.
    public static func announcement(isPaused: Bool) -> String {
        isPaused ? "Ride paused" : "Ride resumed"
    }

    public static let stateChipLabel = "PAUSED"

    /// `m:ss`, growing an hours field past an hour. Clamps negatives to zero.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// The chip's composed VoiceOver read. Spelled out, because "4:12" is read as a time of day.
    public static func chipAccessibilityLabel(pausedSeconds: TimeInterval) -> String {
        let total = Int(max(0, pausedSeconds))
        let (m, s) = (total / 60, total % 60)
        guard m > 0 else { return "Paused for \(s) second\(s == 1 ? "" : "s")" }
        return "Paused for \(m) minute\(m == 1 ? "" : "s") \(s) second\(s == 1 ? "" : "s")"
    }
}
```

- [ ] **Step 4: Add the test identifiers**

In `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift`, inside `enum RideTestID`, after `hudEnd`:

```swift
    /// The cockpit pause/resume control. One identifier for both states — it is one control
    /// whose label changes (ROH-101 P7); assert the state on `hudPausedBanner`, not on this.
    public static let hudPause = "ride.hud.pause"
    /// The PAUSED state chip. Present only while paused, so ROH-103 can assert the state
    /// rather than inferring it from the control's label.
    public static let hudPausedBanner = "ride.hud.paused.banner"
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --package-path AuraCore --no-parallel --filter PauseControlCopy`
Expected: PASS (8 tests).

- [ ] **Step 6: Lint and commit**

```bash
swiftlint lint --strict
git add AuraCore/Sources/AuraCore/Ride/PauseControlCopy.swift AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift AuraCore/Tests/AuraCoreTests/PauseControlCopyTests.swift
git commit -m "feat(roh-101): pause control copy and test identifiers"
```

---

### Task 4: `RideRecorder.currentPauseSeconds(asOf:)`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideRecorder.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideRecorderPauseTests.swift` (append; create if absent)

**Interfaces:**
- Consumes: nothing.
- Produces: `RideRecorder.currentPauseSeconds(asOf: Date) -> TimeInterval`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("The current stop reads zero while recording")
func zeroWhileRecording() {
    let r = RideRecorder(kind: .freeRide)
    let t0 = Date(timeIntervalSince1970: 1000)
    r.start(at: t0)
    #expect(r.currentPauseSeconds(asOf: t0.addingTimeInterval(30)) == 0)
}

@Test("The current stop grows while paused")
func growsWhilePaused() {
    let r = RideRecorder(kind: .freeRide)
    let t0 = Date(timeIntervalSince1970: 1000)
    r.start(at: t0)
    r.pause(at: t0.addingTimeInterval(60))
    #expect(r.currentPauseSeconds(asOf: t0.addingTimeInterval(90)) == 30)
}

@Test("The current stop returns to zero after a resume, unlike the ride total")
func resetsOnResume() {
    let r = RideRecorder(kind: .freeRide)
    let t0 = Date(timeIntervalSince1970: 1000)
    r.start(at: t0)
    r.pause(at: t0.addingTimeInterval(60))
    r.resume(at: t0.addingTimeInterval(120))
    let later = t0.addingTimeInterval(180)
    #expect(r.currentPauseSeconds(asOf: later) == 0)
    // The ride total keeps the banked 60s — this is the distinction the chip needs.
    #expect(r.pausedSeconds(asOf: later) == 60)
}

@Test("A second stop counts only itself")
func secondStopCountsOnlyItself() {
    let r = RideRecorder(kind: .freeRide)
    let t0 = Date(timeIntervalSince1970: 1000)
    r.start(at: t0)
    r.pause(at: t0.addingTimeInterval(60))
    r.resume(at: t0.addingTimeInterval(120))
    r.pause(at: t0.addingTimeInterval(180))
    #expect(r.currentPauseSeconds(asOf: t0.addingTimeInterval(200)) == 20)
    #expect(r.pausedSeconds(asOf: t0.addingTimeInterval(200)) == 80)
}

@Test("A backward clock step cannot produce a negative current stop")
func backwardClockClampsToZero() {
    let r = RideRecorder(kind: .freeRide)
    let t0 = Date(timeIntervalSince1970: 1000)
    r.start(at: t0)
    r.pause(at: t0.addingTimeInterval(60))
    #expect(r.currentPauseSeconds(asOf: t0.addingTimeInterval(30)) == 0)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path AuraCore --no-parallel --filter RideRecorderPause`
Expected: FAIL, `value of type 'RideRecorder' has no member 'currentPauseSeconds'`.

- [ ] **Step 3: Implement**

In `RideRecorder.swift`, immediately after `pausedSeconds(asOf:)`:

```swift
    /// The stop **in progress** only, or zero when recording. `pausedSeconds(asOf:)` is the
    /// ride's running total across every stop, which is the wrong number for a chip that says
    /// how long *this* stop has been (ROH-101 P4).
    ///
    /// `max(0,)` guards a backward wall-clock step mid-stop the same way `pausedSeconds` does.
    /// The chip is additionally clamped non-decreasing by the coordinator, because clamping to
    /// zero here would still let the displayed number fall. The headline active clock has the
    /// same wall-clock weakness and is tracked as ROH-130.
    public func currentPauseSeconds(asOf now: Date) -> TimeInterval {
        guard let start = pauseStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path AuraCore --no-parallel --filter RideRecorderPause`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --strict
git add AuraCore/Sources/AuraKit/RideRecorder.swift AuraCore/Tests/AuraKitTests/RideRecorderPauseTests.swift
git commit -m "feat(roh-101): expose the in-progress stop duration"
```

---

### Task 5: pause and resume haptics, fired by the coordinator

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Guidance/RideHapticCue.swift`
- Modify: `AuraCore/Sources/AuraKit/Guidance/HapticPlaying.swift` (doc only)
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`
- Modify: all 14 `RideSessionCoordinator(` construction sites
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorPauseTests.swift`

**Interfaces:**
- Consumes: `RideHapticCue`, `HapticPlaying` from AuraKit.
- Produces: `RideHapticCue.pause`, `RideHapticCue.resume`; `RideSessionCoordinator.init(..., haptics: any HapticPlaying)` as a **required** parameter positioned after `guidance:`.

- [ ] **Step 1: Write the failing tests**

Append to `RideSessionCoordinatorPauseTests.swift`. That file already has `makeCoordinator(screen:activity:)`, `point(_:_:speed:)`, `pausedRideWithACheckpoint(saving:)`, `ManualLocationProvider` and `waitUntil` — use them rather than writing new ones.

`GuidanceViewModelHapticsTests` already defines a `HapticSpy`, but nested inside its own struct. Promote it to file scope in a shared support file so this task and Task 6 can both use it:

Create `AuraCore/Tests/AuraKitTests/Support/HapticSpy.swift`:

```swift
import AuraCore
@testable import AuraKit

/// Records the cues a collaborator played. Shared by the guidance and coordinator suites.
final class HapticSpy: HapticPlaying {
    var cues: [RideHapticCue] = []
    var prepareCount = 0
    func prepare() { prepareCount += 1 }
    func play(_ cue: RideHapticCue) { cues.append(cue) }
}
```

Then delete the nested copy from `GuidanceViewModelHapticsTests` and let it resolve to this one.

Extend the existing helper in the pause test file (Task 6 adds `nudges:` to the same helper, so keep the defaulted shape):

```swift
    private func makeCoordinator(screen: SpyScreenWake = SpyScreenWake(),
                                 activity: SpyRideActivity = SpyRideActivity(),
                                 haptics: HapticSpy = HapticSpy())
        -> RideSessionCoordinator {
        RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                               screen: screen, activity: activity, haptics: haptics)
    }
```

```swift
@Test func pausingConfirmsWithAHaptic() async throws {
    let store = try RideStore.inMemory()
    let haptics = HapticSpy()
    let location = ManualLocationProvider()
    let c = makeCoordinator(haptics: haptics)
    c.start(location: location, saving: store, units: .metric, authorization: .authorized)
    location.emit(point(40.40, 0))
    #expect(await waitUntil { c.stats.distanceMeters >= 0 })
    c.pause()
    #expect(haptics.cues == [.pause])
}

@Test func resumingConfirmsWithADistinctHaptic() async throws {
    let store = try RideStore.inMemory()
    let haptics = HapticSpy()
    let location = ManualLocationProvider()
    let c = makeCoordinator(haptics: haptics)
    c.start(location: location, saving: store, units: .metric, authorization: .authorized)
    c.pause()
    c.resume()
    #expect(haptics.cues == [.pause, .resume])
    #expect(RideHapticCue.pause != RideHapticCue.resume)
}

@Test func redundantTransitionsPlayNothing() async throws {
    let store = try RideStore.inMemory()
    let haptics = HapticSpy()
    let c = makeCoordinator(haptics: haptics)
    c.start(location: ManualLocationProvider(), saving: store, units: .metric,
            authorization: .authorized)
    c.pause()
    c.pause()   // already paused — guarded
    c.resume()
    c.resume()  // already recording — guarded
    #expect(haptics.cues == [.pause, .resume])
}

@Test func pausingBeforeTheRideStartsPlaysNothing() {
    let haptics = HapticSpy()
    let c = makeCoordinator(haptics: haptics)
    c.pause()
    #expect(haptics.cues.isEmpty)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path AuraCore --no-parallel --filter RideSessionCoordinatorPause`
Expected: FAIL, `type 'RideHapticCue' has no member 'pause'`.

- [ ] **Step 3: Add the cues**

In `RideHapticCue.swift`, replace the type's doc comment first line ("A haptic cue to play during a **navigated ride**.") with:

```swift
/// A haptic cue played during a ride. Turn cues fire only while navigating; the pause and
/// resume confirmations fire on any ride, including a free ride (ROH-101).
```

Then add the cases:

```swift
    /// The rider paused the ride. A confirmation of their own tap, not a guidance cue, so it
    /// is not gated on the turn-haptics setting — the same treatment as the mark-spot haptic.
    case pause
    /// The rider resumed. Deliberately distinct from `.pause` so the two are told apart with
    /// gloves on and the phone in a bar mount.
    case resume
```

- [ ] **Step 4: Correct `HapticPlaying`'s doc comment, which this change falsifies**

Replace the sentence "Guidance-scoped — driven by `GuidanceViewModel`, **not** `RideSessionCoordinator` — so it lives here in `Guidance/` rather than with the coordinator seams in `RideSessionSeams.swift`." with:

```swift
/// Driven by `GuidanceViewModel` for turn cues and by `RideSessionCoordinator` for the pause
/// and resume confirmations (ROH-101). It stays here in `Guidance/` for continuity with the
/// cue type rather than because only guidance uses it.
```

- [ ] **Step 5: Wire the coordinator**

Add the stored property beside the other seams:

```swift
    private let haptics: any HapticPlaying
```

Add to `init`, after `guidance:`, as a **required** parameter:

```swift
                haptics: any HapticPlaying,
```
```swift
        self.haptics = haptics
```

Do **not** give it a default. Four injection points across two HUDs and two seams mean an optional would let a miswired HUD compile clean, pass every host test (they inject doubles) and ship the feature dead — the failure `TrackRibbon.swift:13-14` records. Add this to the init's doc comment:

```swift
    /// `haptics` and `nudges` are required rather than optional on purpose: they are wired at
    /// two production call sites each, and an optional would let a missed one ship silently.
```

In `pause()`, after `recorder.pause(at: now)` and before the `pauseObserver` call:

```swift
        haptics.play(.pause)
```

In `resume()`, after `recorder.resume(at: now)`:

```swift
        haptics.play(.resume)
```

- [ ] **Step 6: Update all 14 construction sites**

```bash
grep -rn "RideSessionCoordinator(" --include="*.swift" Aura AuraCore | grep -v "class RideSessionCoordinator"
```

Every test site gets `haptics: HapticSpy()` (or the target's existing haptic double). The two app sites get `haptics: HapticPlayer.shared`:
- `Aura/Sources/Ride/RideHUDView.swift:58`
- `Aura/Sources/Ride/NavigateHUDView.swift:77`

- [ ] **Step 7: Run the whole suite**

Run: `swift test --package-path AuraCore --no-parallel`
Expected: PASS, both totals clean.

- [ ] **Step 8: Lint and commit**

```bash
swiftlint lint --strict
git add -A
git commit -m "feat(roh-101): confirm pause and resume with distinct haptics"
```

---

### Task 6: the nudge seam and the coordinator's scheduling lifecycle

The most defect-prone task in the plan. Three of the review's blocking findings live here.

**Ordering: run Task 9 before this one.** This task makes `nudges` a required constructor
parameter, so the two HUDs must pass a real conformer for the app to build, and Task 9 is what
creates `PauseNudgeScheduler`. Task 9 in turn needs only `PauseNudgePolicy` (Task 2) and the
seam declared in Step 3 below, so the working order is: Step 3 of this task, then all of Task 9,
then the rest of this task.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorNudgeTests.swift` (create)

**Interfaces:**
- Consumes: `PauseNudgePolicy` (Task 2), the coordinator's `haptics` parameter (Task 5).
- Produces: `RideNudgeScheduling` with `requestAuthorizationIfNeeded() async -> Bool`, `scheduleForgottenPauseNudges(startingAt: Date)`, `cancelForgottenPauseNudges()`; `RideSessionCoordinator.init(..., nudges: any RideNudgeScheduling)` required, after `haptics:`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorNudgeTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore
@testable import AuraKit

@MainActor
final class NudgeSpy: RideNudgeScheduling {
    var authorized = true
    /// Held open to model the real async authorization gap: the alert iOS defers until the app
    /// is active again is exactly the window the generation guard exists for.
    var authorizationGate: CheckedContinuation<Void, Never>?
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0
    private(set) var lastStart: Date?

    func requestAuthorizationIfNeeded() async -> Bool {
        if authorizationGate != nil { return authorized }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            authorizationGate = c
        }
        return authorized
    }
    func openTheGate() { authorizationGate?.resume(); authorizationGate = nil }
    func scheduleForgottenPauseNudges(startingAt: Date) { scheduleCount += 1; lastStart = startingAt }
    func cancelForgottenPauseNudges() { cancelCount += 1 }
}

@MainActor
@Suite(.swiftDataSerialized)
struct RideSessionCoordinatorNudgeTests {
    private func point(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: -80),
                   elevation: 250, timestamp: Date(timeIntervalSince1970: t),
                   speedMetersPerSecond: nil)
    }

    private func makeCoordinator(nudges: NudgeSpy) -> RideSessionCoordinator {
        RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                               screen: SpyScreenWake(), activity: SpyRideActivity(),
                               haptics: HapticSpy(), nudges: nudges)
    }

    /// A started ride carrying enough distance that `RideBackOutGate.canDiscard` is false —
    /// the same two-fix setup `pausedRideWithACheckpoint` uses in the pause suite.
    private func ridePastTheDiscardFloor(_ c: RideSessionCoordinator,
                                         _ location: ManualLocationProvider,
                                         _ store: RideStore) async {
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
    }

    @Test func aPauseAboveTheFloorSchedulesTheLadder() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        nudges.openTheGate()
        #expect(await waitUntil { nudges.scheduleCount == 1 })
    }

    @Test func aPauseBelowTheFloorSchedulesNothing() async throws {
        // A ride the app would itself discard has no business sending notifications, and this
        // gate is what closes the orphan an edge-swipe back-out would otherwise leave behind.
        let nudges = NudgeSpy()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .authorized)
        c.pause()
        nudges.openTheGate()
        await Task.yield()
        #expect(nudges.scheduleCount == 0)
    }

    @Test func resumingBeforeAuthorizationResolvesSchedulesNothing() async throws {
        // The first pause on every install: the wake lock drops, the phone locks, and iOS
        // defers the alert until the app is active again. Without the generation guard the
        // ladder lands after the rider is already riding.
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        c.resume()
        nudges.openTheGate()
        await Task.yield()
        await Task.yield()
        #expect(nudges.scheduleCount == 0)
    }

    @Test func aDeclinedPermissionSchedulesNothing() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        nudges.authorized = false
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        nudges.openTheGate()
        await Task.yield()
        await Task.yield()
        #expect(nudges.scheduleCount == 0)
    }

    @Test func resumeCancels() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        let before = nudges.cancelCount
        c.resume()
        #expect(nudges.cancelCount > before)
    }

    @Test func finishCancels() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        let before = nudges.cancelCount
        c.finish()
        #expect(nudges.cancelCount > before)
    }

    @Test func discardCancels() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        let before = nudges.cancelCount
        c.discard()
        #expect(nudges.cancelCount > before)
    }

    @Test func startingARideClearsWhatAnEarlierOneOrphaned() async throws {
        let nudges = NudgeSpy()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .authorized)
        #expect(nudges.cancelCount == 1)
    }

    @Test func aDeniedRideDoesNotTouchTheNudges() async throws {
        let nudges = NudgeSpy()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .denied)
        #expect(nudges.cancelCount == 0)
    }

    @Test func teardownDoesNotCancel() async throws {
        // A spurious onDisappear on the retained nav root would otherwise silently remove the
        // safety net for a still-paused ride, and pause()'s !isPaused guard means nothing
        // would ever re-arm it for that stop.
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        nudges.openTheGate()
        #expect(await waitUntil { nudges.scheduleCount == 1 })
        let before = nudges.cancelCount
        c.cancel()
        #expect(nudges.cancelCount == before)
    }

    @Test func theLadderIsAnchoredToTheTap() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        let before = Date()
        c.pause()
        nudges.openTheGate()
        #expect(await waitUntil { nudges.scheduleCount == 1 })
        let start = try #require(nudges.lastStart)
        #expect(start.timeIntervalSince(before) >= 0)
        #expect(start.timeIntervalSince(before) < 5)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path AuraCore --no-parallel --filter Nudge`
Expected: FAIL, `cannot find type 'RideNudgeScheduling' in scope`.

- [ ] **Step 3: Add the seam**

Append to `RideSessionSeams.swift`:

```swift
/// Schedules and cancels the forgotten-pause notification ladder. The app conforms a
/// UserNotifications-backed type; the package never imports UserNotifications.
///
/// **Authorization is separate from scheduling on purpose.** Merging them into one synchronous
/// call is unimplementable: `requestAuthorization` is async, and a pause immediately releases
/// the wake lock, so on the first pause of an install the phone locks, iOS defers the alert
/// until the app is active again, and a merged call would schedule the ladder long after the
/// rider resumed. The coordinator awaits authorization and then re-checks that the same pause
/// is still in flight before scheduling.
@MainActor
public protocol RideNudgeScheduling: AnyObject {
    /// Ask the system once per install, if it has not been asked. Returns whether nudges may
    /// be posted; a declined prompt returns false forever after.
    func requestAuthorizationIfNeeded() async -> Bool
    /// Schedule every rung of `PauseNudgePolicy`, offset from `startingAt`, replacing any
    /// already scheduled.
    func scheduleForgottenPauseNudges(startingAt: Date)
    /// Remove every pending and already delivered nudge.
    func cancelForgottenPauseNudges()
}
```

- [ ] **Step 4: Wire the coordinator**

Stored properties beside the other seams:

```swift
    private let nudges: any RideNudgeScheduling
    /// Incremented on every pause. A schedule that resolves after the rider already resumed
    /// carries a stale generation and is dropped.
    private var pauseGeneration = 0
```

`init` gains the required parameter after `haptics:`:

```swift
                nudges: any RideNudgeScheduling,
```
```swift
        self.nudges = nudges
```

In `start()`, immediately after the authorization `switch` (so a denied ride does not touch it):

```swift
        // The one moment the app knows no ride is paused. Clears anything an earlier ride in
        // this same app session orphaned — a below-floor swipe-back, or a schedule that raced.
        nudges.cancelForgottenPauseNudges()
```

Replace the body of `pause()` with:

```swift
    public func pause() {
        guard recorder.isRecording, !recorder.isPaused else { return }
        let now = Date()
        recorder.pause(at: now)
        haptics.play(.pause)
        // Before anything that can yield: an arrival draining after the pause but before
        // guidance knows about it would end the ride under the rider.
        pauseObserver?.rideDidSetPaused(true)
        refreshElapsed(now: now)
        currentPauseSeconds = 0
        screen.setKeepAwake(false)
        flushCheckpoint(at: now)
        scheduleNudges(from: now)
    }

    /// Schedule the forgotten-pause ladder, if this stop is worth one.
    ///
    /// Gated on the same discard floor as `flushCheckpoint`: a ride the app would itself throw
    /// away has no business sending notifications, and that gate is also what stops an
    /// edge-swipe back-out below the floor from orphaning a ladder.
    ///
    /// The generation check after the await is load-bearing, not defensive. See
    /// `RideNudgeScheduling`.
    private func scheduleNudges(from date: Date) {
        guard !RideBackOutGate.canDiscard(distanceMeters: recorder.stats.distanceMeters) else { return }
        pauseGeneration += 1
        let generation = pauseGeneration
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.nudges.requestAuthorizationIfNeeded()
            guard granted, self.pauseGeneration == generation, self.recorder.isPaused else { return }
            self.nudges.scheduleForgottenPauseNudges(startingAt: date)
        }
    }
```

In `resume()`, after `recorder.resume(at: now)`:

```swift
        haptics.play(.resume)
        pauseGeneration += 1          // invalidates any schedule still awaiting authorization
        nudges.cancelForgottenPauseNudges()
        currentPauseSeconds = 0
```

In `finish()`, immediately after the `guard`:

```swift
        pauseGeneration += 1
        nudges.cancelForgottenPauseNudges()
```

In `discard()`, before the `cancel()` call:

```swift
        pauseGeneration += 1
        nudges.cancelForgottenPauseNudges()
```

**Do not touch `cancel()`.** Add this comment above it:

```swift
    /// Deliberately does **not** cancel the pause nudges. This runs from `onDisappear`, which
    /// this codebase documents as firing without the rider asking for anything, and `pause()`'s
    /// `!isPaused` guard means a nudge cancelled here could never be re-armed for a stop still
    /// in progress. Every *legitimate* exit goes through `finish()` or `discard()` first, both
    /// of which cancel; the below-floor path that reaches only `cancel()` never scheduled
    /// anything, because `scheduleNudges` is gated on the discard floor (ROH-101 P5).
```

- [ ] **Step 5: Publish the chip's clock**

Add the observable property next to `elapsed`:

```swift
    /// Duration of the stop in progress, zero while recording. Clamped non-decreasing within a
    /// stop: a backward wall-clock step would otherwise make the chip count down while the
    /// headline active clock jumps forward in the same tick (ROH-130 owns the headline).
    public private(set) var currentPauseSeconds: TimeInterval = 0
```

Extend `refreshElapsed`:

```swift
    private func refreshElapsed(now: Date = Date()) {
        guard let startedAt else { return }
        elapsed = max(0, now.timeIntervalSince(startedAt) - recorder.pausedSeconds(asOf: now))
        currentPauseSeconds = max(currentPauseSeconds, recorder.currentPauseSeconds(asOf: now))
    }
```

`pause()` and `resume()` already reset it to 0 above, which is what makes the `max` safe across stops.

- [ ] **Step 6: Update the 14 construction sites again**

Every test site gains `nudges: NudgeSpy()`. The two HUD sites gain `nudges: PauseNudgeScheduler.shared`, which **Task 9 creates** — see the ordering note in this task's header.

- [ ] **Step 7: Run the whole suite**

Run: `swift test --package-path AuraCore --no-parallel`
Expected: PASS.

- [ ] **Step 8: Lint and commit**

```bash
swiftlint lint --strict
git add -A
git commit -m "feat(roh-101): schedule and cancel the forgotten-pause ladder"
```

---

### Task 7: turn haptics fall silent while paused

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift`
- Test: `AuraCore/Tests/AuraKitTests/GuidanceViewModelHapticsTests.swift`

**Interfaces:**
- Consumes: `GuidanceViewModel.isPaused` (already present, set via `RidePauseObserving`).
- Produces: no new API.

- [ ] **Step 1: Write the failing test**

Append to `GuidanceViewModelHapticsTests`, matching the `ScriptedGuidanceSession` pattern the
file already uses (the 140 m rung is what trips `TurnHapticEngine` in `enabledFiresApproachThenArrival`):

```swift
    @Test func pausedFiresNoTurnHaptic() async {
        // Spoken instructions are already suppressed while paused. Leaving the haptic firing
        // means a rider at lunch with the phone pocketed still gets buzzed about turns they
        // are not taking, and on an accidental pause the surviving buzz is what convinces them
        // nothing is wrong while the voice has gone silent.
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Right onto Penn Ave"))
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = true
        vm.rideDidSetPaused(true)
        await vm.run(route: makeRoute())
        #expect(spy.cues.isEmpty)
    }

    @Test func resumingRestoresTurnHaptics() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Right onto Penn Ave"))
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = true
        vm.rideDidSetPaused(true)
        vm.rideDidSetPaused(false)
        await vm.run(route: makeRoute())
        #expect(spy.cues == [.approach])
    }
```

Note this suite's `HapticSpy` moved to file scope in Task 5; if Task 5 has not run yet, keep using the nested one and let Task 5 do the promotion.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path AuraCore --no-parallel --filter GuidanceViewModelHaptics`
Expected: FAIL, the spy recorded one cue where none was expected.

- [ ] **Step 3: Implement**

In `applyProgress`, change the haptic line to match the gate the spoken branch already uses:

```swift
        // Same gate as `.spokenInstruction`: a rider who does not need to be told about the
        // turn does not need to be buzzed about it either (ROH-101 P1).
        if hapticsEnabled, !isPaused, let cue { haptics?.play(cue) }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path AuraCore --no-parallel --filter GuidanceViewModelHaptics`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --strict
git add AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift AuraCore/Tests/AuraKitTests/GuidanceViewModelHapticsTests.swift
git commit -m "fix(roh-101): stop turn haptics while the ride is paused"
```

---

### Task 8: the roster cap becomes a pinned constant

**Files:**
- Create: `AuraCore/Sources/AuraCore/Theme/HUDLayoutMetrics.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift:456`
- Test: `AuraCore/Tests/AuraCoreTests/HUDLayoutMetricsTests.swift`

**Interfaces:**
- Produces: `HUDLayoutMetrics.groupRosterMaxHeightFraction: Double`, `HUDLayoutMetrics.groupRosterFallbackMaxHeight: Double`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AuraCore

@Suite("HUD layout metrics")
struct HUDLayoutMetricsTests {
    @Test("The roster cap is the documented lever for an iPhone SE overflow")
    func rosterCapIsPinned() {
        // ROH-101 adds a pause row to a column that already holds a turn card, the roster, the
        // control cluster and a quarter-screen panel. If the SE overflows, this fraction is the
        // agreed lever — pinned so lowering it is a deliberate, reviewed change.
        #expect(HUDLayoutMetrics.groupRosterMaxHeightFraction == 0.4)
    }

    @Test("The cap leaves room for the rest of the cockpit column")
    func capLeavesRoomForTheColumn() {
        // Panel 25% + roster cap must not alone exceed the screen.
        #expect(HUDLayoutMetrics.groupRosterMaxHeightFraction + 0.25 < 1.0)
    }

    @Test("The pre-layout fallback height is positive and finite")
    func fallbackIsSane() {
        #expect(HUDLayoutMetrics.groupRosterFallbackMaxHeight > 0)
        #expect(HUDLayoutMetrics.groupRosterFallbackMaxHeight.isFinite)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path AuraCore --no-parallel --filter HUDLayoutMetrics`
Expected: FAIL, `cannot find 'HUDLayoutMetrics' in scope`.

- [ ] **Step 3: Implement**

Create `AuraCore/Sources/AuraCore/Theme/HUDLayoutMetrics.swift`:

```swift
import Foundation

/// Cockpit layout limits kept as plain values so they can be pinned by a test, in the spirit
/// of `HUDControlMetrics`.
public enum HUDLayoutMetrics {
    /// Share of HUD height the group roster may occupy before it is capped.
    ///
    /// ROH-101 inserted a pause row below the control cluster, so on a group navigate ride the
    /// column now stacks a turn card, this roster, a four-entry cluster, the pause row and a
    /// panel pinned at a quarter of the screen. The column does not clip when it overflows: it
    /// grows upward and pushes the cluster, End included, under the turn card. This fraction is
    /// the agreed lever if an iPhone SE overflows, and it is pinned by a test so lowering it is
    /// a reviewed decision rather than something remembered from a device session.
    public static let groupRosterMaxHeightFraction = 0.4

    /// Used until the HUD has been measured once.
    public static let groupRosterFallbackMaxHeight = 320.0
}
```

- [ ] **Step 4: Use it in the view**

`NavigateHUDView.swift:456` becomes:

```swift
                        .frame(maxHeight: hudHeight > 0
                               ? hudHeight * HUDLayoutMetrics.groupRosterMaxHeightFraction
                               : HUDLayoutMetrics.groupRosterFallbackMaxHeight,
                               alignment: .bottom)
```

- [ ] **Step 5: Run and build**

Run: `swift test --package-path AuraCore --no-parallel --filter HUDLayoutMetrics`
Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
swiftlint lint --strict
git add AuraCore/Sources/AuraCore/Theme/HUDLayoutMetrics.swift AuraCore/Tests/AuraCoreTests/HUDLayoutMetricsTests.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "refactor(roh-101): pin the group roster height cap"
```

---

### Task 9: the app-target notification conformer, delegate and launch clear

No unit test target exists in the app, so compilation plus the device pass are the checks. Keep logic out of here.

**Files:**
- Create: `Aura/Sources/Notifications/PauseNudgeScheduler.swift`
- Create: `Aura/Sources/Notifications/AuraAppDelegate.swift`
- Modify: `Aura/Sources/Ride/HapticPlayer.swift`
- Modify: `Aura/Sources/AuraApp.swift`

**Interfaces:**
- Consumes: `PauseNudgePolicy`, `RideNudgeScheduling`, `RideHapticCue.pause`/`.resume`.
- Produces: `PauseNudgeScheduler.shared`, `AuraAppDelegate`.

- [ ] **Step 1: Add the two haptics**

In `HapticPlayer.swift`, add the generators:

```swift
    /// A softer, settling tap for a pause. Distinct in character from `.resume`, which is a
    /// rising double, so the two are told apart with gloves on and the phone in a bar mount.
    private let pauseGenerator = UIImpactFeedbackGenerator(style: .soft)
```

Extend `prepare()`:

```swift
        pauseGenerator.prepare()
```

Extend `play(_:)`:

```swift
        case .pause:
            pauseGenerator.impactOccurred()
            pauseGenerator.prepare()
        case .resume:
            // A rising double against the pause's single soft tap. `.rigid` for the crispness
            // that survives a bar mount and a glove.
            approachGenerator.impactOccurred(intensity: 0.7)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [approachGenerator] in
                approachGenerator.impactOccurred(intensity: 1.0)
                approachGenerator.prepare()
            }
```

- [ ] **Step 2: Write the scheduler**

Create `Aura/Sources/Notifications/PauseNudgeScheduler.swift`:

```swift
import UserNotifications
import os
import AuraCore
import AuraKit

/// Posts the forgotten-pause ladder. The app-target shell behind AuraKit's
/// `RideNudgeScheduling`, the analog of `WorkoutWriter` and `RideLiveActivityController`.
///
/// Holds no policy: every offset, identifier and string comes from `PauseNudgePolicy`, which is
/// unit-tested on the host. This type only talks to `UNUserNotificationCenter`.
@MainActor
final class PauseNudgeScheduler: NSObject, RideNudgeScheduling {
    static let shared = PauseNudgeScheduler()

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "app.aura.ios", category: "pause-nudge")

    private override init() { super.init() }

    /// The system prompts once per install and returns the stored answer afterwards, so this is
    /// safe to call on every pause. Requests sound as well as alerts: a silent banner on a
    /// locked phone is invisible to the rider who needs it.
    func requestAuthorizationIfNeeded() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func scheduleForgottenPauseNudges(startingAt: Date) {
        cancelForgottenPauseNudges()
        let elapsed = max(0, Date().timeIntervalSince(startingAt))
        for rung in PauseNudgePolicy.rungs {
            // Anchor to the tap, not to now: authorization may have taken a while to resolve.
            let remaining = rung.after - elapsed
            guard remaining >= 60 else { continue }   // a time-interval trigger's floor
            let content = UNMutableNotificationContent()
            content.title = rung.title
            content.body = rung.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: rung.identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false))
            center.add(request) { [log] error in
                if let error { log.error("Nudge add failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        log.info("Scheduled pause nudges")
    }

    func cancelForgottenPauseNudges() {
        center.removePendingNotificationRequests(withIdentifiers: PauseNudgePolicy.allIdentifiers)
        center.removeDeliveredNotifications(withIdentifiers: PauseNudgePolicy.allIdentifiers)
    }
}

extension PauseNudgeScheduler: UNUserNotificationCenterDelegate {
    /// Without this, iOS shows nothing while the app is active — and a rider paused to read the
    /// map, with the HUD on screen, is exactly that case (ROH-101 P5).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
```

- [ ] **Step 3: Write the app delegate**

Create `Aura/Sources/Notifications/AuraAppDelegate.swift`:

```swift
import UIKit
import UserNotifications

/// Exists only to install the notification-centre delegate before launch finishes. A delegate
/// set later than that misses a launch-time tap response, and without one iOS suppresses every
/// foreground banner.
final class AuraAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil)
    -> Bool {
        UNUserNotificationCenter.current().delegate = PauseNudgeScheduler.shared
        return true
    }
}
```

- [ ] **Step 4: Adopt the delegate and clear orphans at launch**

In `AuraApp.swift`, add to the `App` type:

```swift
    @UIApplicationDelegateAdaptor(AuraAppDelegate.self) private var appDelegate
```

In `RootView`'s existing launch `.task`, before the backfill sweep:

```swift
            // Clear any pause nudge an earlier process orphaned. A jetsam kill during a pause,
            // which is the likely end of a long stop, leaves the ladder scheduled with nobody
            // left to cancel it.
            //
            // Safe **only** because a persisted checkpoint is never resumable: a pause writes a
            // real row (ROH-107's badge is for exactly that row), so "nothing persists an
            // in-flight ride" is false — what is true is that nothing restores one. If
            // checkpoint restore ever lands, this becomes "destroy the nudges for the ride we
            // just restored" and must move behind that check.
            //
            // Idempotent, which matters: this `.task` re-runs on a scene reconnect, the same
            // hazard the V6 backfill sweep had to be guarded against.
            if router.activeRideID == nil {
                PauseNudgeScheduler.shared.cancelForgottenPauseNudges()
            }
```

Read `AuraApp.swift:93` and the surrounding `.task` before editing; match how the backfill sweep guards its own re-entry, and use whatever property actually reports an active ride there.

- [ ] **Step 5: Point the HUDs at the real scheduler**

In both `RideHUDView.swift:58` and `NavigateHUDView.swift:77`, the coordinator gains:

```swift
            haptics: HapticPlayer.shared, nudges: PauseNudgeScheduler.shared,
```

- [ ] **Step 6: Build**

```bash
cd Aura && xcodegen generate && cd ..
xcodebuild build -project Aura/Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Lint and commit**

```bash
swiftlint lint --strict
git add -A
git commit -m "feat(roh-101): post the pause-nudge ladder, foreground included"
```

---

### Task 10: the `PauseControl` view

**Files:**
- Create: `Aura/Sources/Ride/PauseControl.swift`
- Modify: `Aura/Sources/Shared/UnfinishedRideBadge.swift` (doc comment only)

**Interfaces:**
- Consumes: `PauseControlCopy`, `RideTestID.hudPause`, `RideTestID.hudPausedBanner`, `HUDControlMetrics.ride`.
- Produces: `PauseControl(isPaused:pausedSeconds:onToggle:)`.

- [ ] **Step 1: Write the view**

Create `Aura/Sources/Ride/PauseControl.swift`:

```swift
import SwiftUI
import AuraCore
import AuraKit

/// The cockpit's pause/resume row: one control whose label tracks the state, plus a PAUSED chip
/// carrying a live count of the current stop.
///
/// **Resume is the wider control, and that is the whole point.** Pause is pressed deliberately
/// while stopping and needs no more than a comfortable target. Resume is pressed while clipping
/// in, gloved and one-handed (spec D9, ROH-75). Sizing it the other way round would also put the
/// largest tap target on the ride screen along the bottom edge, where a rain film and a
/// supporting thumb both land, for an action taken on a minority of rides.
///
/// The row is a constant 56 pt in both states, so nothing below it moves when the rider taps.
/// 56 pt is `HUDControlMetrics.ride.resolvedHitTarget`, the target ROH-75 settled on.
///
/// Mint, never amber: amber already carries peer-stopped and weak or lost GPS, so a rider paused
/// under a railway bridge would otherwise see two amber elements meaning different things.
struct PauseControl: View {
    let isPaused: Bool
    /// Duration of the stop in progress. Ignored while recording.
    let pausedSeconds: TimeInterval
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var rowHeight: CGFloat { CGFloat(HUDControlMetrics.ride.resolvedHitTarget) }

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            if isPaused {
                stateChip
            } else {
                Spacer(minLength: 0)
            }
            control
        }
        .frame(height: rowHeight)
        .animation(.snappy, value: isPaused)
    }

    private var stateChip: some View {
        HStack(spacing: AuraTheme.Spacing.xs) {
            Text(PauseControlCopy.stateChipLabel)
                .font(.caption.weight(.bold))
                .foregroundStyle(AuraTheme.textPrimary)
            Text(PauseControlCopy.clock(pausedSeconds))
                .font(AuraTheme.Typography.metricCockpit(17, relativeTo: .subheadline))
                .foregroundStyle(AuraTheme.textPrimary)
                .contentTransition(.numericText())
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, AuraTheme.Spacing.md)
        .frame(height: rowHeight)
        .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(AuraTheme.hairline(contrast)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PauseControlCopy.chipAccessibilityLabel(pausedSeconds: pausedSeconds))
        .accessibilityIdentifier(RideTestID.hudPausedBanner)
    }

    private var control: some View {
        Button(action: onToggle) {
            HStack(spacing: AuraTheme.Spacing.sm) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                Text(PauseControlCopy.buttonLabel(isPaused: isPaused))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.headline.weight(.semibold))
            .foregroundStyle(isPaused ? AuraTheme.onAccent : AuraTheme.textPrimary)
            // Paused fills the rest of the row; recording stays compact so the accidental-tap
            // surface along the bottom edge is small.
            .frame(maxWidth: isPaused ? .infinity : nil)
            .frame(height: rowHeight)
            .padding(.horizontal, isPaused ? AuraTheme.Spacing.lg : AuraTheme.Spacing.xl)
            .background {
                if isPaused {
                    Capsule().fill(AuraTheme.accent)
                } else {
                    Capsule()
                        .fill(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast))
                        .overlay(Capsule().strokeBorder(AuraTheme.hairline(contrast)))
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(PauseControlCopy.accessibilityLabel(isPaused: isPaused))
        .accessibilityIdentifier(RideTestID.hudPause)
    }
}

#Preview("Both states") {
    VStack(spacing: 24) {
        PauseControl(isPaused: false, pausedSeconds: 0, onToggle: {})
        PauseControl(isPaused: true, pausedSeconds: 252, onToggle: {})
    }
    .padding()
    .background(AuraTheme.background)
}
```

- [ ] **Step 2: Correct the badge comment this falsifies**

`UnfinishedRideBadge.swift:12-14` currently says the rider "just learned `pause.circle` in the HUD". Replace that sentence with:

```swift
/// **Not a pause glyph.** The rider just learned `pause.fill` and `play.fill` in the HUD, where
/// they mean "paused and resumable". Here the meaning is the opposite: this ride can never be
/// resumed or ended. A clock says "when" without promising an action.
```

- [ ] **Step 3: Build and eyeball both previews**

```bash
cd Aura && xcodegen generate && cd ..
xcodebuild build -project Aura/Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Lint and commit**

```bash
swiftlint lint --strict
git add Aura/Sources/Ride/PauseControl.swift Aura/Sources/Shared/UnfinishedRideBadge.swift
git commit -m "feat(roh-101): the cockpit pause/resume control"
```

---

### Task 11: the held cockpit, and Navigate's ARRIVE

**Files:**
- Modify: `Aura/Sources/Ride/InstrumentChassis.swift`
- Modify: `Aura/Sources/Ride/InstrumentPanel.swift`
- Modify: `Aura/Sources/Ride/ExploreInstrumentPanel.swift`

**Interfaces:**
- Produces: an `isPaused: Bool = false` parameter on `InstrumentChassis`, `InstrumentPanel` and `ExploreInstrumentPanel`.

- [ ] **Step 1: Add the flag to the chassis**

In `InstrumentChassis`, add the property after `columnAccessibilityLabel`:

```swift
    /// While paused, the readouts drop to secondary weight so a frozen clock looks deliberately
    /// frozen rather than broken.
    ///
    /// `AuraTheme.textSecondary`, never an opacity multiplier on `textPrimary`:
    /// `AuraPaletteContrastTests` guards the token against the panel, and it cannot see through
    /// a composition. This must also stay pure styling — adding a `Text` here would break the
    /// one-composed-VoiceOver-element invariant documented above.
    var isPaused: Bool = false
```

Add a computed colour and use it in both places that currently use `AuraTheme.textPrimary`:

```swift
    private var readoutColor: Color { isPaused ? AuraTheme.textSecondary : AuraTheme.textPrimary }
```

In `speedInstrument`, replace `.foregroundStyle(AuraTheme.textPrimary)` with `.foregroundStyle(readoutColor)`.

`CockpitInstrument` gains the same flag:

```swift
struct CockpitInstrument: View {
    let value: String
    let label: String
    var isPaused: Bool = false
```
and its value `Text` uses `.foregroundStyle(isPaused ? AuraTheme.textSecondary : AuraTheme.textPrimary)`.

- [ ] **Step 2: Thread it through Explore**

`ExploreInstrumentPanel` gains `var isPaused: Bool = false`, passes `isPaused: isPaused` to `InstrumentChassis`, and passes `isPaused: isPaused` to each of its three `CockpitInstrument`s.

- [ ] **Step 3: Thread it through Navigate, and blank ARRIVE**

`InstrumentPanel` gains `var isPaused: Bool = false` and passes it to the chassis. Its column becomes:

```swift
                CockpitInstrument(value: trip.distanceRemaining ?? "–", label: "TO GO",
                                  isPaused: isPaused)
                // A paused ride has no meaningful arrival time: guidance keeps running, so after
                // a 45-minute lunch this would count down past the arrival and then display a
                // time in the past. The "–" fallback already exists for a missing ETA; a stopped
                // rider is the same case (ROH-101 P4).
                CockpitInstrument(value: isPaused ? "–" : (trip.eta ?? "–"), label: "ARRIVE",
                                  isPaused: isPaused)
```

- [ ] **Step 4: Add a paused preview to each panel**

Add a second `#Preview("Paused")` to both panel files, identical to the existing preview but with `isPaused: true`.

- [ ] **Step 5: Build**

```bash
xcodebuild build -project Aura/Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Lint and commit**

```bash
swiftlint lint --strict
git add Aura/Sources/Ride/InstrumentChassis.swift Aura/Sources/Ride/InstrumentPanel.swift Aura/Sources/Ride/ExploreInstrumentPanel.swift
git commit -m "feat(roh-101): hold the cockpit readouts while paused"
```

---

### Task 12: the paused ribbon and the calmed turn card

**Files:**
- Modify: `AuraCore/Sources/AuraKit/TurnCardPresenter.swift`
- Modify: `Aura/Sources/Ride/RideMapView.swift`
- Test: `AuraCore/Tests/AuraKitTests/TurnCardPresenterTests.swift`

**Interfaces:**
- Consumes: `TrackRibbon.Piece.Style` (Task 1).
- Produces: `TurnCardState.calmed() -> TurnCardState`; an `isPaused: Bool = false` parameter on `RideMapView`.

- [ ] **Step 1: Write the failing test**

```swift
@Test("A calmed card drops its imminent-turn emphasis and keeps everything else")
func calmedDropsEmphasisOnly() {
    let expanded = TurnCardState(primaryText: "Right onto Penn Ave", distanceText: "90 ft",
                                 isExpanded: true,
                                 accessibilityLabel: "In 90 feet, Right onto Penn Ave")
    let calm = expanded.calmed()
    #expect(calm.isExpanded == false)
    #expect(calm.primaryText == expanded.primaryText)
    #expect(calm.distanceText == expanded.distanceText)
    #expect(calm.accessibilityLabel == expanded.accessibilityLabel)
    #expect(calm.maneuver == expanded.maneuver)
}

@Test("Calming an already calm card changes nothing")
func calmingIsIdempotent() {
    let calm = TurnCardState.starting
    #expect(calm.calmed() == calm)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path AuraCore --no-parallel --filter TurnCardPresenter`
Expected: FAIL, `value of type 'TurnCardState' has no member 'calmed'`.

- [ ] **Step 3: Implement the transform**

In `TurnCardPresenter.swift`, inside `TurnCardState`:

```swift
    /// The same card without its imminent-turn emphasis.
    ///
    /// A paused rider is not about to take the turn, and the expanded card is a solid mint fill
    /// that would otherwise compete with the mint Resume control directly below it. The text is
    /// kept: the rider stopped mid-route and the next instruction is still what they will want
    /// when they set off (ROH-101 P4, discharging ROH-105 D5's positive-signal requirement
    /// together with the state chip and the paused ribbon).
    public func calmed() -> TurnCardState {
        var copy = self
        copy.isExpanded = false
        return copy
    }
```

- [ ] **Step 4: Style the paused ribbon**

In `RideMapView`, add the parameter next to `segments`:

```swift
    /// Whether the ride is stopped. Styles the run the rider paused in, so the map itself says
    /// recording has stopped (ROH-105 D5's pure discriminator, computed in `TrackRibbon`).
    var isPaused: Bool = false
```

Change `ribbonPieces`:

```swift
    private var ribbonPieces: [TrackRibbon.Piece] {
        TrackRibbon.pieces(segments: segments, isPaused: isPaused)
    }
```

In `routeRibbon`, replace the `.lineColor(...)` call with a style that honours the piece:

```swift
                .lineColor(StyleColor(strokeColor(for: piece)))
                .lineWidth(6)
                .lineOpacity(piece.style == .paused ? 0.55 : 1)
                // Dashes read as "not being drawn right now" at a glance, and unlike a colour
                // change they survive a rider who cannot distinguish the two hues.
                .lineDasharray(piece.style == .paused ? [2, 2] : [])
```

and add:

```swift
    /// The recorded track's stroke. A detour dims the whole ribbon so the bright detour line
    /// wins; the paused run is dimmed and dashed on top of whichever of those applies.
    private func strokeColor(for piece: TrackRibbon.Piece) -> UIColor {
        detourRoute.isEmpty
            ? AuraTheme.routeUIColor
            : UIColor(AuraTheme.routeLine.opacity(0.25))
    }
```

Verify `lineDasharray` and `lineOpacity` exist on `PolylineAnnotation` in the pinned MapboxMaps 11.27.0 before relying on them. If either is unavailable, drop that modifier and carry the paused state on colour alone, then say so in the task report.

- [ ] **Step 5: Run and build**

```bash
swift test --package-path AuraCore --no-parallel --filter TurnCardPresenter
xcodebuild build -project Aura/Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: PASS, BUILD SUCCEEDED.

- [ ] **Step 6: Lint and commit**

```bash
swiftlint lint --strict
git add -A
git commit -m "feat(roh-101): mark the paused run on the map and calm the turn card"
```

---

### Task 13: wire both HUDs

The task where a mistake ships the feature dead on one screen. Do both HUDs in this one commit.

**Files:**
- Modify: `Aura/Sources/Ride/RideHUDView.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Consumes: `PauseControl`, `coordinator.isPaused`, `coordinator.currentPauseSeconds`, `PauseControlCopy.announcement(isPaused:)`.

- [ ] **Step 1: Add the row to Explore**

In `RideHUDView.bottomCockpit`, between the cluster `HStack` and `ExploreInstrumentPanel`:

```swift
            PauseControl(isPaused: coordinator.isPaused,
                         pausedSeconds: coordinator.currentPauseSeconds,
                         onToggle: { togglePause() })
                .padding(.horizontal, AuraTheme.Spacing.lg)
```

Pass the paused flag to the map and the panel:

```swift
            RideMapView(segments: coordinator.segments,
                        isPaused: coordinator.isPaused,
```
```swift
            ExploreInstrumentPanel(
                currentSpeedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
                units: settings.units,
                isPaused: coordinator.isPaused,
```

Add to the `RideHUDView` extension:

```swift
    /// Toggle the pause, then tell VoiceOver what happened. The announcement lives here rather
    /// than behind a seam because `UIAccessibility` is UIKit and AuraKit does not import it;
    /// both HUDs call this same shared control, so it is still written once per HUD and never
    /// duplicated inside the control itself.
    func togglePause() {
        let wasPaused = coordinator.isPaused
        if wasPaused { coordinator.resume() } else { coordinator.pause() }
        AccessibilityAnnouncer.announce(PauseControlCopy.announcement(isPaused: !wasPaused))
    }
```

- [ ] **Step 2: Add the announcer**

Create `Aura/Sources/Shared/AccessibilityAnnouncer.swift`:

```swift
import UIKit

/// Posts a VoiceOver announcement. One place, so both HUDs cannot drift, and so the current
/// API lives in exactly one file when it next changes.
enum AccessibilityAnnouncer {
    static func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }
}
```

Confirm `AccessibilityNotification.Announcement` and `accessibilitySpeechAnnouncementPriority` against the `ios-accessibility` skill before writing this; if the skill gives a different current spelling, follow the skill and note the difference in the task report.

- [ ] **Step 3: Add the row to Navigate**

In `NavigateHUDView.bottomCockpit`, between the cluster `HStack` and `InstrumentPanel`:

```swift
            PauseControl(isPaused: coordinator.isPaused,
                         pausedSeconds: coordinator.currentPauseSeconds,
                         onToggle: { togglePause() })
                .padding(.horizontal, AuraTheme.Spacing.lg)
```

Pass the flag to the panel and the map, exactly as Explore does, and calm the turn card. Find where `TurnCardView(state:)` is constructed and change the state to:

```swift
            TurnCardView(state: coordinator.isPaused ? guidance.turn.calmed() : guidance.turn,
```

Add the same `togglePause()` to this view's extension.

- [ ] **Step 4: Verify both HUDs are wired**

```bash
grep -n "PauseControl(" Aura/Sources/Ride/RideHUDView.swift Aura/Sources/Ride/NavigateHUDView.swift
grep -n "haptics:\|nudges:" Aura/Sources/Ride/RideHUDView.swift Aura/Sources/Ride/NavigateHUDView.swift
grep -n "isPaused" Aura/Sources/Ride/RideHUDView.swift Aura/Sources/Ride/NavigateHUDView.swift
```
Expected: both files appear in all three greps. If either is missing from any, the feature is dead on that HUD.

- [ ] **Step 5: Build**

```bash
xcodebuild build -project Aura/Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Lint and commit**

```bash
swiftlint lint --strict
git add -A
git commit -m "feat(roh-101): wire the pause control into both ride HUDs"
```

---

### Task 14: the Settings recovery path

**Files:**
- Modify: `Aura/Sources/Settings/SettingsView.swift`
- Create: `Aura/Sources/Settings/PauseRemindersRow.swift`

**Interfaces:**
- Consumes: `PauseNudgeScheduler`, `RideSettingsLink.open`.

- [ ] **Step 1: Write the row**

Create `Aura/Sources/Settings/PauseRemindersRow.swift`:

```swift
import SwiftUI
import UserNotifications
import AuraCore

/// Shows whether pause reminders can be delivered, and offers a way back when they cannot.
///
/// The system prompts once per install. A rider who taps Don't Allow at a junction, which is
/// exactly where the first pause tends to happen, would otherwise lose the only mechanism that
/// reaches a pocketed phone, permanently and with nothing telling them so.
struct PauseRemindersRow: View {
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pause reminders")
                    .foregroundStyle(AuraTheme.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status == .denied {
                Button("Open Settings") { RideSettingsLink.open() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AuraTheme.accent)
            }
        }
        .task {
            status = await UNUserNotificationCenter.current().notificationSettings()
                .authorizationStatus
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch status {
        case .denied:
            return "Off. Aura can't remind you when a paused ride is still paused."
        case .authorized, .provisional, .ephemeral:
            return "On. Aura reminds you if a paused ride stays paused."
        default:
            return "Aura asks the first time you pause a ride."
        }
    }
}
```

- [ ] **Step 2: Add it to Settings**

Place it in the same section as the Health access row. Read `SettingsView.swift` around line 74 and follow the section structure already there.

- [ ] **Step 3: Build**

```bash
xcodebuild build -project Aura/Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Full suite, lint, commit**

```bash
swift test --package-path AuraCore --no-parallel
swiftlint lint --strict
git add -A
git commit -m "feat(roh-101): a way back from a declined reminder prompt"
```

---

## Definition of done for the branch

- [ ] `swift test --package-path AuraCore --no-parallel` clean, both totals.
- [ ] `swiftlint lint --strict` clean from the repo root.
- [ ] App builds for the simulator.
- [ ] `grep -c "PauseControl(" ` returns 1 for each HUD file.
- [ ] Every device-verification item in the spec is either checked on hardware or explicitly listed as outstanding on the PR.
