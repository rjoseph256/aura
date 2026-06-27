# Aura Wave 3 — Home and Lock Screen widgets implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Last ride" widget and a "Weekly goal" widget to the existing `AuraWidgets` extension, fed by a denormalized snapshot the app writes into a shared App Group.

**Architecture:** A pure `WidgetSnapshot` value + factory in AuraKit (built and unit-tested on the macOS CI host) is written to an App Group JSON file by an app-target refresher when ride/settings data changes, and read by a WidgetKit `TimelineProvider` in the extension. No SwiftData, Mapbox, or WidgetKit enters the package; the extension shares `AuraTheme` and `RouteThumbnail` by target membership, as the Live Activity already does.

**Tech Stack:** Swift 6.2 / Xcode 26, SwiftUI, WidgetKit, XcodeGen, Swift Testing, SwiftLint 0.64.1.

## Global Constraints

- Swift 6 language mode across all targets; UI-bound `@Observable`/seam types stay `@MainActor`; prefer `static let` over `static var` for type statics.
- The SwiftPM package (`AuraCore`, `AuraKit`) MUST build on the macOS CI host: no SwiftUI/UIKit/WidgetKit/ActivityKit/Mapbox in the package; any iOS-only API there is `#if os(iOS)` guarded.
- SwiftLint `--strict` over the WHOLE repo (`scripts/lint.sh`, pinned 0.64.1) must pass at every task gate: `line_length ≤ 140`; a tuple of >2 members becomes a `struct`; no `implicit_optional_initialization` (never write `var x: T? = nil` as a stored property — drop the `= nil`).
- Any app-target OR AuraWidgets file ADD/DELETE (and any `project.yml`/entitlements change) requires `xcodegen generate` in `Aura/`. Package files under `AuraCore/Sources/**` are auto-globbed and never touch `project.yml`. New files under `Aura/Widgets/**` (widget target) and `Aura/Sources/**` (app target) are picked up by existing globs and need no `project.yml` edit, but still require `xcodegen generate`.
- NEVER `git add AuraCore/Package.resolved` (revert with `git checkout -- AuraCore/Package.resolved` if a build dirties it). Never commit `Aura/Aura.xcodeproj` (generated) or `Aura/Resources/MapboxAccessToken` (gitignored).
- App Group id is `group.app.aura.ios`. Bundle ids: app `app.aura.ios`, extension `app.aura.ios.AuraWidgets`. DEVELOPMENT_TEAM for signed sim builds: `Y9HGZ8Z97R`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Delegate all builds/tests/lint/simulator to the `apple-platform-build-tools:builder` subagent.

---

### Task 1: `WidgetSnapshot` + factory (AuraKit, pure, TDD)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Widgets/WidgetSnapshot.swift`
- Test: `AuraCore/Tests/AuraKitTests/WidgetSnapshotTests.swift`

**Interfaces:**
- Consumes: `RideSummary`, `Ride.Kind`, `Coordinate` (AuraCore); `DistanceUnits`, `WeeklyRideStats`, `RideAggregator.weekToDate`/`mostRecent` (AuraKit).
- Produces: `WidgetSnapshot` (Codable/Equatable/Sendable) with `currentVersion`, nested `LastRide` and `Week` (with `fraction`/`percent`), `make(summaries:goalMeters:units:now:calendar:)`, `weekReset()`, `sample`.

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraKitTests/WidgetSnapshotTests.swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite struct WidgetSnapshotTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday
        return c
    }
    private func date(_ day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
    private func summary(day: Int, distance: Double?, moving: Double = 600,
                         elevation: Double = 30, thumb: [Coordinate] = []) -> RideSummary {
        let start = date(day)
        return RideSummary(id: UUID(), kind: .navigate, startedAt: start,
                           endedAt: start.addingTimeInterval(moving),
                           hasStats: distance != nil, distanceMeters: distance ?? 0,
                           movingTimeSeconds: distance == nil ? 0 : moving,
                           elevationGainMeters: distance == nil ? 0 : elevation,
                           destinationName: nil, thumbnailCoordinates: thumb)
    }
    private var now: Date { date(24) } // Wed Jun 24 2026; week = Mon 22 … Mon 29 (exclusive)

    @Test func make_derivesWeekAndLastRide() {
        let snap = WidgetSnapshot.make(
            summaries: [summary(day: 22, distance: 1000), summary(day: 24, distance: 2000),
                        summary(day: 21, distance: 5000)],
            goalMeters: 40_000, units: .metric, now: now, calendar: cal)
        #expect(snap.week.distanceMeters == 3000)
        #expect(snap.week.rideCount == 2)
        #expect(snap.week.goalMeters == 40_000)
        #expect(snap.units == .metric)
        #expect(snap.lastRide?.startedAt == date(24))
        #expect(snap.week.start == cal.dateInterval(of: .weekOfYear, for: now)!.start)
        #expect(snap.week.end == cal.dateInterval(of: .weekOfYear, for: now)!.end)
    }

    @Test func make_emptySummaries_nilLastRide_zeroWeek() {
        let snap = WidgetSnapshot.make(summaries: [], goalMeters: 25_000,
                                       units: .imperial, now: now, calendar: cal)
        #expect(snap.lastRide == nil)
        #expect(snap.week.distanceMeters == 0)
        #expect(snap.week.rideCount == 0)
        #expect(snap.week.goalMeters == 25_000)
    }

    @Test func make_statlessMostRecent_carriesHasStatsFalse() {
        let snap = WidgetSnapshot.make(summaries: [summary(day: 24, distance: nil)],
                                       goalMeters: 40_000, units: .imperial, now: now, calendar: cal)
        #expect(snap.lastRide?.hasStats == false)
        #expect(snap.lastRide?.distanceMeters == 0)
    }

    @Test func week_fractionAndPercent_matchWeeklyRideStats() {
        let over = WidgetSnapshot.Week(distanceMeters: 30_000, rideCount: 2,
                                       goalMeters: 25_000, start: now, end: now)
        #expect(abs(over.fraction - 1.0) < 0.0001) // clamped at the goal
        #expect(over.percent == 120)               // uncapped
        let zeroGoal = WidgetSnapshot.Week(distanceMeters: 10, rideCount: 1,
                                           goalMeters: 0, start: now, end: now)
        #expect(zeroGoal.fraction == 0)
        #expect(zeroGoal.percent == 0)
    }

    @Test func weekReset_zeroesWeekKeepsGoalIntervalAndLastRide() {
        let snap = WidgetSnapshot.make(summaries: [summary(day: 24, distance: 5000)],
                                       goalMeters: 40_000, units: .metric, now: now, calendar: cal)
        let reset = snap.weekReset()
        #expect(reset.week.distanceMeters == 0)
        #expect(reset.week.rideCount == 0)
        #expect(reset.week.goalMeters == 40_000)
        #expect(reset.week.start == snap.week.start)
        #expect(reset.week.end == snap.week.end)
        #expect(reset.lastRide == snap.lastRide)
    }

    @Test func codable_roundTrips() throws {
        let snap = WidgetSnapshot.make(
            summaries: [summary(day: 24, distance: 5000,
                                thumb: [Coordinate(latitude: 40.4, longitude: -79.9),
                                        Coordinate(latitude: 40.5, longitude: -80.0)])],
            goalMeters: 40_000, units: .imperial, now: now, calendar: cal)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded == snap)
        #expect(decoded.version == WidgetSnapshot.currentVersion)
        #expect(decoded.lastRide?.thumbnailCoordinates.count == 2)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Delegate to the builder: `swift test --package-path AuraCore` (or the AuraKitTests target). Expected: FAIL — `cannot find 'WidgetSnapshot' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// AuraCore/Sources/AuraKit/Widgets/WidgetSnapshot.swift
import Foundation
import AuraCore

/// The denormalized projection the home / Lock Screen widgets read. The app builds it
/// from `RideStore.summaries()` + settings and writes it into the App Group container;
/// the widget decodes it with no SwiftData. It lives in AuraKit (it reuses
/// `DistanceUnits`, `WeeklyRideStats`, and `RideAggregator`) but imports no
/// SwiftUI/UIKit/WidgetKit, so it builds and tests on the macOS CI host.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Bumped if the stored shape changes; a reader rejects an unknown version, so a new
    /// widget binary ignores a snapshot an old app wrote (and vice versa) until the app
    /// rewrites it.
    public static let currentVersion = 1

    public struct LastRide: Codable, Equatable, Sendable {
        public let id: UUID
        public let kind: Ride.Kind
        public let startedAt: Date
        public let hasStats: Bool
        public let distanceMeters: Double
        public let movingTimeSeconds: Double
        public let elevationGainMeters: Double
        public let destinationName: String?
        public let thumbnailCoordinates: [Coordinate]

        public init(id: UUID, kind: Ride.Kind, startedAt: Date, hasStats: Bool,
                    distanceMeters: Double, movingTimeSeconds: Double,
                    elevationGainMeters: Double, destinationName: String?,
                    thumbnailCoordinates: [Coordinate]) {
            self.id = id; self.kind = kind; self.startedAt = startedAt
            self.hasStats = hasStats; self.distanceMeters = distanceMeters
            self.movingTimeSeconds = movingTimeSeconds
            self.elevationGainMeters = elevationGainMeters
            self.destinationName = destinationName
            self.thumbnailCoordinates = thumbnailCoordinates
        }

        init(_ summary: RideSummary) {
            self.init(id: summary.id, kind: summary.kind, startedAt: summary.startedAt,
                      hasStats: summary.hasStats, distanceMeters: summary.distanceMeters,
                      movingTimeSeconds: summary.movingTimeSeconds,
                      elevationGainMeters: summary.elevationGainMeters,
                      destinationName: summary.destinationName,
                      thumbnailCoordinates: summary.thumbnailCoordinates)
        }
    }

    public struct Week: Codable, Equatable, Sendable {
        public let distanceMeters: Double
        public let rideCount: Int
        public let goalMeters: Double
        public let start: Date
        public let end: Date

        public init(distanceMeters: Double, rideCount: Int, goalMeters: Double,
                    start: Date, end: Date) {
            self.distanceMeters = distanceMeters; self.rideCount = rideCount
            self.goalMeters = goalMeters; self.start = start; self.end = end
        }

        private var stats: WeeklyRideStats {
            WeeklyRideStats(distanceMeters: distanceMeters, rideCount: rideCount,
                            elevationGainMeters: 0, movingTimeSeconds: 0)
        }
        /// Clamped 0...1 for the gauge / ring arc.
        public var fraction: Double { stats.goalFraction(goalMeters: goalMeters) }
        /// Uncapped whole percent (an over-goal week reads > 100).
        public var percent: Int { stats.goalPercent(goalMeters: goalMeters) }
    }

    public let version: Int
    public let generatedAt: Date
    public let units: DistanceUnits
    public let lastRide: LastRide?
    public let week: Week

    public init(version: Int = WidgetSnapshot.currentVersion, generatedAt: Date,
                units: DistanceUnits, lastRide: LastRide?, week: Week) {
        self.version = version; self.generatedAt = generatedAt
        self.units = units; self.lastRide = lastRide; self.week = week
    }

    /// Builds the snapshot from the cheap summary projection + settings. `now` is injected
    /// (not `Date()`) so the factory is deterministic and testable.
    public static func make(summaries: [RideSummary], goalMeters: Double,
                            units: DistanceUnits, now: Date,
                            calendar: Calendar = .current) -> WidgetSnapshot {
        let weekly = RideAggregator.weekToDate(summaries, now: now, calendar: calendar)
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: now, end: now)
        let last = RideAggregator.mostRecent(summaries).map(LastRide.init)
        return WidgetSnapshot(
            generatedAt: now, units: units, lastRide: last,
            week: Week(distanceMeters: weekly.distanceMeters, rideCount: weekly.rideCount,
                       goalMeters: goalMeters, start: interval.start, end: interval.end))
    }

    /// A copy with the week figures zeroed for the new week (goal, interval, and last ride
    /// preserved) — the provider's week-boundary entry.
    public func weekReset() -> WidgetSnapshot {
        WidgetSnapshot(version: version, generatedAt: generatedAt, units: units,
                       lastRide: lastRide,
                       week: Week(distanceMeters: 0, rideCount: 0, goalMeters: week.goalMeters,
                                  start: week.start, end: week.end))
    }

    /// Canned content for the gallery placeholder and previews. Fixed timestamps keep it
    /// deterministic.
    public static let sample = WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
        units: .imperial,
        lastRide: LastRide(id: UUID(), kind: .freeRide,
                           startedAt: Date(timeIntervalSince1970: 1_749_900_000),
                           hasStats: true, distanceMeters: 20_000, movingTimeSeconds: 3_720,
                           elevationGainMeters: 104, destinationName: nil,
                           thumbnailCoordinates: []),
        week: Week(distanceMeters: 20_000, rideCount: 3, goalMeters: 40_000,
                   start: Date(timeIntervalSince1970: 1_749_600_000),
                   end: Date(timeIntervalSince1970: 1_750_204_800)))
}
```

- [ ] **Step 4: Run the test to verify it passes**

Delegate to the builder: `swift test --package-path AuraCore`. Expected: PASS (all `WidgetSnapshotTests`).

- [ ] **Step 5: Lint and commit**

Run `scripts/lint.sh` (whole repo, `--strict`). Then:

```bash
git add AuraCore/Sources/AuraKit/Widgets/WidgetSnapshot.swift AuraCore/Tests/AuraKitTests/WidgetSnapshotTests.swift
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git commit -m "feat(core): WidgetSnapshot value + factory for widgets

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `WidgetSnapshotStore` + `AppGroup` (AuraKit, pure, TDD)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Widgets/WidgetSnapshotStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/WidgetSnapshotStoreTests.swift`

**Interfaces:**
- Consumes: `WidgetSnapshot` (Task 1).
- Produces: `AppGroup.identifier`; `WidgetSnapshotStore(directory:)`, `WidgetSnapshotStore.appGroup()`, `write(_:)`, `read() -> WidgetSnapshot?`.

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraKitTests/WidgetSnapshotStoreTests.swift
import Testing
import Foundation
@testable import AuraKit

@Suite struct WidgetSnapshotStoreTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writeThenRead_returnsEqualSnapshot() {
        let store = WidgetSnapshotStore(directory: tempDir())
        store.write(.sample)
        #expect(store.read() == .sample)
    }

    @Test func read_missingFile_returnsNil() {
        #expect(WidgetSnapshotStore(directory: tempDir()).read() == nil)
    }

    @Test func read_corruptFile_returnsNil() throws {
        let dir = tempDir()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("widget-snapshot.json"))
        #expect(WidgetSnapshotStore(directory: dir).read() == nil)
    }

    @Test func read_versionMismatch_returnsNil() throws {
        let dir = tempDir()
        let json = """
        {"version":999,"generatedAt":0,"units":"imperial","lastRide":null,\
        "week":{"distanceMeters":0,"rideCount":0,"goalMeters":40000,"start":0,"end":0}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("widget-snapshot.json"))
        #expect(WidgetSnapshotStore(directory: dir).read() == nil)
    }

    @Test func nilDirectory_writeNoOps_readNil() {
        let store = WidgetSnapshotStore(directory: nil)
        store.write(.sample) // must not crash
        #expect(store.read() == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Delegate to the builder: `swift test --package-path AuraCore`. Expected: FAIL — `cannot find 'WidgetSnapshotStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// AuraCore/Sources/AuraKit/Widgets/WidgetSnapshotStore.swift
import Foundation

/// The shared App Group identifier. The app writes the widget snapshot into this group's
/// container and the widget reads it; one constant stops the two sides from drifting.
public enum AppGroup {
    public static let identifier = "group.app.aura.ios"
}

/// Reads and writes the `WidgetSnapshot` as a JSON file. The directory is injected so the
/// store is testable on the macOS CI host with a temp directory; production resolves the
/// App Group container (nil, and a graceful no-op, when the entitlement is absent — e.g. an
/// unsigned build or the CI host).
public struct WidgetSnapshotStore {
    private let directory: URL?
    private let fileName = "widget-snapshot.json"

    /// Inject a directory in tests; production uses `appGroup()`.
    public init(directory: URL?) { self.directory = directory }

    /// The shared App-Group-backed store the app writes and the widget reads.
    public static func appGroup() -> WidgetSnapshotStore {
        WidgetSnapshotStore(directory: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier))
    }

    public func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Returns nil when the container is unavailable, the file is missing, the JSON fails to
    /// decode, or the version is unrecognized. Every failure folds to "no snapshot", which
    /// the widget views render as their empty state.
    public func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    private var fileURL: URL? { directory?.appendingPathComponent(fileName) }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Delegate to the builder: `swift test --package-path AuraCore`. Expected: PASS.

- [ ] **Step 5: Lint and commit**

Run `scripts/lint.sh`. Then:

```bash
git add AuraCore/Sources/AuraKit/Widgets/WidgetSnapshotStore.swift AuraCore/Tests/AuraKitTests/WidgetSnapshotStoreTests.swift
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git commit -m "feat(core): App Group WidgetSnapshotStore (directory-injected)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: App Group entitlements + share `RouteThumbnail` into the extension (XcodeGen)

**Files:**
- Modify: `Aura/Resources/Aura.entitlements`
- Create: `Aura/Widgets/AuraWidgets.entitlements`
- Modify: `Aura/project.yml` (AuraWidgets target only)

**Interfaces:**
- Produces: the `group.app.aura.ios` capability on both targets; `RouteThumbnail` compiled into `AuraWidgets`.

- [ ] **Step 1: Add the App Group to the app entitlements**

Replace the contents of `Aura/Resources/Aura.entitlements` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.healthkit</key>
  <true/>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.app.aura.ios</string>
  </array>
</dict>
</plist>
```

- [ ] **Step 2: Create the extension entitlements**

```xml
<!-- Aura/Widgets/AuraWidgets.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.app.aura.ios</string>
  </array>
</dict>
</plist>
```

- [ ] **Step 3: Wire the extension in `project.yml`**

In `Aura/project.yml`, under the `AuraWidgets` target: (a) add `AuraWidgets.entitlements` to the `Widgets` source `excludes`; (b) add the `RouteThumbnail.swift` path; (c) add `CODE_SIGN_ENTITLEMENTS`. The `AuraWidgets` `sources` and `settings.base` become:

```yaml
    sources:
      - path: Widgets
        excludes:
          - Info.plist
          - AuraWidgets.entitlements
      - path: Sources/LiveActivity/RideActivityAttributes.swift
      - path: Sources/Theme/AuraTheme.swift
      - path: Sources/Theme/StatPair.swift
      - path: Sources/Theme/SpeedReadout.swift
      - path: Sources/Shared/RouteThumbnail.swift
      - path: Resources/Fonts
    dependencies:
      - package: AuraCore
        product: AuraCore
      - package: AuraCore
        product: AuraKit
    settings:
      base:
        INFOPLIST_FILE: Widgets/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: app.aura.ios.AuraWidgets
        GENERATE_INFOPLIST_FILE: NO
        TARGETED_DEVICE_FAMILY: "1"
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_ENTITLEMENTS: Widgets/AuraWidgets.entitlements
        SWIFT_VERSION: "6.0"
        SWIFT_APPROACHABLE_CONCURRENCY: YES
        SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
```

- [ ] **Step 4: Regenerate and build**

Delegate to the builder, run in `Aura/`: `xcodegen generate`, then build the app for the iOS Simulator unsigned (`xcodebuild build -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`, which also builds `AuraWidgets`). Expected: BUILD SUCCEEDED (the extension now compiles `RouteThumbnail`; the bundle still hosts only the Live Activity). Run `scripts/lint.sh`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Aura/Resources/Aura.entitlements Aura/Widgets/AuraWidgets.entitlements Aura/project.yml
git commit -m "feat(app): App Group on app + AuraWidgets, share RouteThumbnail

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

(Do NOT commit `Aura/Aura.xcodeproj`.)

---

### Task 4: App-target `WidgetRefresh` + five trigger sites

**Files:**
- Create: `Aura/Sources/Widgets/WidgetRefresh.swift`
- Modify: `Aura/Sources/AuraApp.swift` (RootView: launch + foreground)
- Modify: `Aura/Sources/Ride/RideHUDView.swift` (finish trigger)
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift` (finish trigger)
- Modify: `Aura/Sources/History/HistoryView.swift` (delete trigger)
- Modify: `Aura/Sources/Settings/SettingsView.swift` (goal + units triggers)

**Interfaces:**
- Consumes: `WidgetSnapshot.make`, `WidgetSnapshotStore.appGroup()` (Tasks 1–2); `RideStore.summaries()`, `SettingsStore` (existing).
- Produces: `WidgetRefresh.reload(rideStore:settings:now:)`.

- [ ] **Step 1: Create the refresher**

```swift
// Aura/Sources/Widgets/WidgetRefresh.swift
import WidgetKit
import AuraKit

/// Rebuilds the widget snapshot from the persisted summaries + settings and asks WidgetKit
/// to reload. Called whenever the data the widgets show changes: a ride finishes, a ride is
/// deleted, the weekly goal or units change, and on launch / foreground. The only WidgetKit
/// symbol in the app target.
@MainActor
enum WidgetRefresh {
    private static let store = WidgetSnapshotStore.appGroup()

    static func reload(rideStore: RideStore, settings: SettingsStore, now: Date = Date()) {
        let summaries = (try? rideStore.summaries()) ?? []
        let snapshot = WidgetSnapshot.make(summaries: summaries,
                                           goalMeters: settings.weeklyGoalMeters,
                                           units: settings.units, now: now)
        store.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
```

- [ ] **Step 2: Trigger on launch + foreground (RootView)**

In `Aura/Sources/AuraApp.swift`, the `RootView` struct: add environment reads and refresh hooks. Add these properties to `RootView`:

```swift
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
```

and attach to the `TabView` (after the existing `.tint(AuraTheme.accent)`):

```swift
        .task { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        }
```

- [ ] **Step 3: Trigger on ride finish (both HUDs)**

In `Aura/Sources/Ride/RideHUDView.swift`, add after the existing `.onChange(of: coordinator.isRecording)` modifier (around line 50):

```swift
        .onChange(of: coordinator.finishedRide) { _, ride in
            if ride != nil { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        }
```

In `Aura/Sources/Ride/NavigateHUDView.swift`, add the identical modifier after the existing `.onChange(of: coordinator.isRecording)` (around line 161). `rideStore` and `settings` are already in both views' environment.

- [ ] **Step 4: Trigger on ride deletion (History)**

In `Aura/Sources/History/HistoryView.swift`, the `delete(_:)` method becomes:

```swift
    private func delete(_ summary: RideSummary) {
        try? store.delete(id: summary.id)
        summaries.removeAll { $0.id == summary.id }
        WidgetRefresh.reload(rideStore: store, settings: settings)
    }
```

(`store` and `settings` are already in `HistoryView`'s environment.)

- [ ] **Step 5: Trigger on goal + units change (Settings)**

In `Aura/Sources/Settings/SettingsView.swift`, add `@Environment(RideStore.self) private var rideStore` next to the existing `@Environment(SettingsStore.self) private var settings`, and attach to the root `List` (or whatever the `body`'s top container is):

```swift
        .onChange(of: settings.weeklyGoalMeters) { _, _ in
            WidgetRefresh.reload(rideStore: rideStore, settings: settings)
        }
        .onChange(of: settings.units) { _, _ in
            WidgetRefresh.reload(rideStore: rideStore, settings: settings)
        }
```

- [ ] **Step 6: Regenerate, build, lint**

Delegate to the builder: in `Aura/`, `xcodegen generate` (a new app-target file was added), then build the app unsigned for the iOS Simulator. Expected: BUILD SUCCEEDED. Run `scripts/lint.sh`. Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Aura/Sources/Widgets/WidgetRefresh.swift Aura/Sources/AuraApp.swift Aura/Sources/Ride/RideHUDView.swift Aura/Sources/Ride/NavigateHUDView.swift Aura/Sources/History/HistoryView.swift Aura/Sources/Settings/SettingsView.swift
git commit -m "feat(app): WidgetRefresh writes the snapshot on data changes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Widget timeline plumbing + shared helpers (AuraWidgets)

**Files:**
- Create: `Aura/Widgets/WidgetTimeline.swift`
- Create: `Aura/Widgets/WidgetSupport.swift`

**Interfaces:**
- Consumes: `WidgetSnapshot`, `WidgetSnapshotStore` (Tasks 1–2); `AuraTheme`, `RideStatsFormatter`.
- Produces: `SnapshotEntry`, `SnapshotProvider`; `Date.widgetWeekday`, `WidgetSnapshot.LastRide.kindCaption`/`movingTimeText()`, `WidgetStat`.

- [ ] **Step 1: Create the timeline provider**

```swift
// Aura/Widgets/WidgetTimeline.swift
import WidgetKit
import AuraKit

/// One timeline entry: the decoded snapshot (nil → empty state). Shared by both widgets.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Reads the App-Group snapshot the app writes; never fetches. Emits an entry for now plus a
/// week-boundary reset entry so the weekly total self-corrects across the week turnover even
/// if the app stays closed. One instance per widget.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot: WidgetSnapshot? = context.isPreview
            ? .sample : WidgetSnapshotStore.appGroup().read()
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        guard let snapshot = WidgetSnapshotStore.appGroup().read() else {
            completion(Timeline(entries: [SnapshotEntry(date: now, snapshot: nil)], policy: .atEnd))
            return
        }
        var entries = [SnapshotEntry(date: now, snapshot: snapshot)]
        if snapshot.week.end > now {
            entries.append(SnapshotEntry(date: snapshot.week.end, snapshot: snapshot.weekReset()))
        }
        completion(Timeline(entries: entries, policy: .after(snapshot.week.end)))
    }
}
```

- [ ] **Step 2: Create the shared widget helpers**

```swift
// Aura/Widgets/WidgetSupport.swift
import SwiftUI
import AuraCore
import AuraKit

extension Date {
    /// Abbreviated weekday, e.g. "Tue".
    var widgetWeekday: String { formatted(.dateTime.weekday(.abbreviated)) }
}

extension WidgetSnapshot.LastRide {
    /// "Free ride" or the navigated destination name.
    var kindCaption: String {
        kind == .navigate ? (destinationName ?? "Ride") : "Free ride"
    }
    /// Moving time as "1:02" (h:mm) for an hour or more, else "12:30" (m:ss).
    var movingTimeText: String {
        Duration.seconds(movingTimeSeconds)
            .formatted(.time(pattern: movingTimeSeconds >= 3600 ? .hourMinute : .minuteSecond))
    }
}

/// A small cockpit stat cell for the medium widget: a Saira value over a muted label.
struct WidgetStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
            Text(value)
                .font(AuraTheme.Typography.metricCockpit(18, relativeTo: .body))
                .foregroundStyle(AuraTheme.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1)
        }
    }
}
```

- [ ] **Step 3: Regenerate and build**

Delegate to the builder: in `Aura/`, `xcodegen generate` (two new extension files), then build the app unsigned for the iOS Simulator. Expected: BUILD SUCCEEDED (the provider compiles; nothing references it yet). Run `scripts/lint.sh`. Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add Aura/Widgets/WidgetTimeline.swift Aura/Widgets/WidgetSupport.swift
git commit -m "feat(widgets): snapshot TimelineProvider + shared helpers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `WeeklyGoalWidget` (four families) + register

**Files:**
- Create: `Aura/Widgets/WeeklyGoalWidget.swift`
- Modify: `Aura/Widgets/AuraWidgetBundle.swift`

**Interfaces:**
- Consumes: `SnapshotEntry`, `SnapshotProvider` (Task 5); `AuraTheme`, `RideStatsFormatter`, `WidgetSnapshot.Week`.
- Produces: `WeeklyGoalWidget` (registered in the bundle).

- [ ] **Step 1: Create the widget**

```swift
// Aura/Widgets/WeeklyGoalWidget.swift
import SwiftUI
import WidgetKit
import AuraCore
import AuraKit

/// Home + Lock Screen widget: progress toward the weekly distance goal. The small family
/// mirrors the home dashboard's WeeklyRing; the Lock Screen families use system Gauges.
/// Honors the rider's units via the snapshot.
struct WeeklyGoalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.aura.widgets.weeklyGoal", provider: SnapshotProvider()) { entry in
            WeeklyGoalView(entry: entry)
                .widgetURL(URL(string: "aura://plan"))
        }
        .configurationDisplayName("Weekly goal")
        .description("Your distance this week toward your goal.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct WeeklyGoalView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var week: WidgetSnapshot.Week? { entry.snapshot?.week }
    private var units: DistanceUnits { entry.snapshot?.units ?? .imperial }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    private var small: some View {
        let week = self.week
        return VStack(spacing: 6) {
            ZStack {
                Circle().stroke(AuraTheme.border, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: week?.fraction ?? 0)
                    .stroke(AuraTheme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(fmt.distanceValue(week?.distanceMeters ?? 0))
                        .font(AuraTheme.Typography.metricCockpit(28, relativeTo: .title))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text(fmt.distanceUnit.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AuraTheme.textSecondary)
                }
            }
            Text(goalCaption(week))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AuraTheme.accent)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .padding(12)
        .containerBackground(AuraTheme.background, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance this week")
        .accessibilityValue(accessibilityValue(week))
    }

    private var circular: some View {
        Gauge(value: week?.fraction ?? 0, in: 0...1) {
            Text(fmt.distanceUnit)
        } currentValueLabel: {
            Text(fmt.distanceValue(week?.distanceMeters ?? 0))
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel("Distance this week")
        .accessibilityValue(accessibilityValue(week))
    }

    private var rectangular: some View {
        let week = self.week
        return VStack(alignment: .leading, spacing: 2) {
            Text("This week").font(.headline)
            Text("\(fmt.distanceValue(week?.distanceMeters ?? 0)) / "
                 + "\(fmt.distanceValue(week?.goalMeters ?? 0)) \(fmt.distanceUnit)")
                .font(.body)
            Gauge(value: week?.fraction ?? 0, in: 0...1) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
            Text("\(week?.percent ?? 0)% · \(week?.rideCount ?? 0) rides").font(.caption)
        }
        .widgetAccentable()
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance this week")
        .accessibilityValue(accessibilityValue(week))
    }

    private var inline: some View {
        let week = self.week
        return Label(
            "\(fmt.distanceValue(week?.distanceMeters ?? 0)) of "
                + "\(fmt.distanceValue(week?.goalMeters ?? 0)) \(fmt.distanceUnit) this week",
            systemImage: "bicycle")
            .widgetAccentable()
    }

    private func goalCaption(_ week: WidgetSnapshot.Week?) -> String {
        guard let week else { return "No rides yet" }
        return "\(week.percent)% of \(fmt.distanceValue(week.goalMeters)) \(fmt.distanceUnit)"
    }

    private func accessibilityValue(_ week: WidgetSnapshot.Week?) -> String {
        guard let week else { return "No rides yet" }
        return "\(fmt.distanceValue(week.distanceMeters)) \(fmt.distanceUnit), "
            + "\(week.percent) percent of weekly goal"
    }
}
```

- [ ] **Step 2: Register it in the bundle**

```swift
// Aura/Widgets/AuraWidgetBundle.swift
import SwiftUI
import WidgetKit

/// The widget extension's entry point: the in-progress-ride Live Activity plus the
/// home / Lock Screen timeline widgets.
@main
struct AuraWidgetBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivity()
        WeeklyGoalWidget()
    }
}
```

- [ ] **Step 3: Regenerate and build**

Delegate to the builder: in `Aura/`, `xcodegen generate`, then build the app unsigned for the iOS Simulator. Expected: BUILD SUCCEEDED. Run `scripts/lint.sh`. Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add Aura/Widgets/WeeklyGoalWidget.swift Aura/Widgets/AuraWidgetBundle.swift
git commit -m "feat(widgets): Weekly goal widget (4 families)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: `LastRideWidget` (three families) + register

**Files:**
- Create: `Aura/Widgets/LastRideWidget.swift`
- Modify: `Aura/Widgets/AuraWidgetBundle.swift`

**Interfaces:**
- Consumes: `SnapshotEntry`, `SnapshotProvider`, `WidgetStat`, `Date.widgetWeekday`, `WidgetSnapshot.LastRide.movingTimeText`/`kindCaption`, `RouteThumbnail` (shared in Task 3).
- Produces: `LastRideWidget` (registered in the bundle).

- [ ] **Step 1: Create the widget**

```swift
// Aura/Widgets/LastRideWidget.swift
import SwiftUI
import WidgetKit
import AuraCore
import AuraKit

/// Home + Lock Screen widget: the most recent ride at a glance — a map-free thumbnail, the
/// hero distance, and (medium) a stat column mirroring the dashboard's last-ride card.
struct LastRideWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.aura.widgets.lastRide", provider: SnapshotProvider()) { entry in
            LastRideView(entry: entry)
                .widgetURL(URL(string: entry.snapshot?.lastRide == nil ? "aura://ride" : "aura://history"))
        }
        .configurationDisplayName("Last ride")
        .description("Your most recent ride at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct LastRideView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var ride: WidgetSnapshot.LastRide? { entry.snapshot?.lastRide }
    private var units: DistanceUnits { entry.snapshot?.units ?? .imperial }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryRectangular: rectangular
        default: small
        }
    }

    private var small: some View {
        Group {
            if let ride {
                VStack(alignment: .leading, spacing: 6) {
                    RouteThumbnail(coordinates: ride.thumbnailCoordinates).frame(height: 54)
                    Spacer(minLength: 0)
                    distanceHero(ride)
                    Text("\(ride.startedAt.widgetWeekday) · \(ride.kindCaption)")
                        .font(.system(size: 11)).foregroundStyle(AuraTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            } else {
                emptyContent
            }
        }
        .padding(12)
        .containerBackground(AuraTheme.background, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var medium: some View {
        Group {
            if let ride {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        RouteThumbnail(coordinates: ride.thumbnailCoordinates)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        distanceHero(ride)
                        Text("Last ride · \(ride.startedAt.widgetWeekday)")
                            .font(.system(size: 11)).foregroundStyle(AuraTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Divider().overlay(AuraTheme.border)
                    VStack(alignment: .leading, spacing: 12) {
                        WidgetStat(label: "MOVING", value: ride.hasStats ? ride.movingTimeText : "—")
                        WidgetStat(label: "CLIMB",
                                   value: ride.hasStats
                                       ? "\(fmt.elevationValue(ride.elevationGainMeters)) \(fmt.elevationUnit)"
                                       : "—")
                    }
                    .frame(width: 92, alignment: .leading)
                }
            } else {
                emptyContent
            }
        }
        .padding(14)
        .containerBackground(AuraTheme.background, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var rectangular: some View {
        Group {
            if let ride {
                HStack(spacing: 8) {
                    RouteThumbnail(coordinates: ride.thumbnailCoordinates, lineColor: .primary)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Last ride · \(ride.startedAt.widgetWeekday)").font(.caption)
                        Text("\(ride.hasStats ? fmt.distanceValue(ride.distanceMeters) : "—") \(fmt.distanceUnit)")
                            .font(.headline)
                        if ride.hasStats {
                            Text("\(ride.movingTimeText) · \(fmt.elevationValue(ride.elevationGainMeters)) \(fmt.elevationUnit) climb")
                                .font(.caption2)
                        }
                    }
                }
            } else {
                Label("No rides yet", systemImage: "bicycle")
            }
        }
        .widgetAccentable()
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func distanceHero(_ ride: WidgetSnapshot.LastRide) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(ride.hasStats ? fmt.distanceValue(ride.distanceMeters) : "—")
                .font(AuraTheme.Typography.metricCockpit(30, relativeTo: .title))
                .foregroundStyle(AuraTheme.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(fmt.distanceUnit)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bicycle").font(.title2).foregroundStyle(AuraTheme.accent)
            Spacer(minLength: 0)
            Text("No rides yet")
                .font(.system(.headline, design: .rounded)).foregroundStyle(AuraTheme.textPrimary)
            Text("Start a ride")
                .font(.system(size: 12)).foregroundStyle(AuraTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var accessibilityLabel: String {
        guard let ride else { return "No rides yet. Start a ride." }
        guard ride.hasStats else { return "Last ride, \(ride.startedAt.widgetWeekday)" }
        return "Last ride, \(ride.startedAt.widgetWeekday), "
            + "\(fmt.distanceValue(ride.distanceMeters)) \(fmt.distanceUnit), "
            + "moving time \(ride.movingTimeText)"
    }
}
```

- [ ] **Step 2: Register it in the bundle**

```swift
// Aura/Widgets/AuraWidgetBundle.swift
import SwiftUI
import WidgetKit

/// The widget extension's entry point: the in-progress-ride Live Activity plus the
/// home / Lock Screen timeline widgets.
@main
struct AuraWidgetBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivity()
        WeeklyGoalWidget()
        LastRideWidget()
    }
}
```

- [ ] **Step 3: Regenerate and build**

Delegate to the builder: in `Aura/`, `xcodegen generate`, then build the app unsigned for the iOS Simulator. Expected: BUILD SUCCEEDED. Run `scripts/lint.sh`. Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add Aura/Widgets/LastRideWidget.swift Aura/Widgets/AuraWidgetBundle.swift
git commit -m "feat(widgets): Last ride widget (3 families)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Simulator verification (signed) + final holistic review

**Files:** none (verification only).

The App Group container resolves only when the entitlement is baked at link time, so verification builds SIGNED (unlike CI). Delegate to the builder.

- [ ] **Step 1: Build signed and install on the iPhone 17 / iOS 26 simulator**

In `Aura/`: `xcodegen generate`, then
`xcodebuild build -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=Y9HGZ8Z97R`.
Find the product with `xcodebuild -showBuildSettings … | grep TARGET_BUILD_DIR` (authoritative path; do NOT trust mtime). Install the `.app` and launch it so the app writes the first snapshot.

- [ ] **Step 2: Seed real data**

Either drive a free ride with simulated GPS (`xcrun simctl location <udid> start --speed=9 --interval=1 <lat,lon> <lat,lon> …`, then end the ride), or confirm existing saved rides are present. Confirm the app wrote the snapshot: the App Group file exists under the data container (`xcrun simctl get_app_container <udid> app.aura.ios group.app.aura.ios` → `…/widget-snapshot.json`).

- [ ] **Step 3: Add and verify every widget family**

Add from the gallery to the Home Screen: Weekly goal (systemSmall) and Last ride (systemSmall, systemMedium). Add to the Lock Screen: Weekly goal (accessoryCircular, accessoryRectangular, accessoryInline) and Last ride (accessoryRectangular). For each, capture a screenshot AND read the accessibility tree (prefer the a11y tree over pixel diffs; reboot the sim with shutdown+boot if a screenshot md5 matches the prior frame). Confirm each shows the REAL last ride and REAL weekly-goal progress (not the sample), formatted in the rider's units.

- [ ] **Step 4: Verify the update path**

Finish a new ride (or change the weekly goal in Settings, or delete a ride in History) and confirm the widgets update without relaunching the app (the snapshot is rewritten and `reloadAllTimelines` fires). Confirm the empty state by testing a fresh install with no rides (Weekly goal shows 0%/goal, Last ride shows "No rides yet / Start a ride"). Note StandBy as a device-only boundary not provable on the simulator.

- [ ] **Step 5: Final holistic review**

Dispatch a final whole-branch review on the most capable model (spec-compliance + Swift 6 concurrency + WidgetKit correctness + accessibility + the mono-lime design). Address any blocking findings, re-run the package tests, the unsigned app build, and `scripts/lint.sh`. No code commit in this task unless a fix is needed.

---

### Task 9: ROADMAP — mark Wave 3 item 3 shipped + Wave 3 COMPLETE

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Replace the widgets bullet**

In `docs/ROADMAP.md`, replace the Wave 3 widgets bullet ("A home and lock-screen widget for the last ride and weekly goal, reusing the `AuraWidgets` extension…") with a SHIPPED bullet describing the denormalized `WidgetSnapshot` (AuraKit) written into the `group.app.aura.ios` App Group by `WidgetRefresh` on data changes, read by two static widgets (Weekly goal: 4 families; Last ride: 3 families) via a snapshot `TimelineProvider` with a week-boundary reset entry, `RouteThumbnail`/`AuraTheme` shared by target membership, entitlements wired through XcodeGen, package-safe (no WidgetKit in the package), unit-tested snapshot + store, and simulator-verified on Home + Lock Screen. Run the bullet through the `humanizer` lens. Note that StandBy is a device-only boundary.

- [ ] **Step 2: Mark Wave 3 complete**

Update the Wave 3 section heading/intro to note all three sub-projects (HealthKit, haptics, widgets) shipped — Wave 3 COMPLETE.

- [ ] **Step 3: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): mark Wave 3 widgets shipped; Wave 3 complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** snapshot + factory (Task 1 ↔ spec §AuraKit snapshot); store + AppGroup (Task 2 ↔ §App Group store); entitlements/XcodeGen/RouteThumbnail share (Task 3 ↔ §App Group, entitlements, XcodeGen); refresher + 5 triggers (Task 4 ↔ §App target refresher, incl. the History-delete trigger from the spec-review); provider/entries/policy/placeholder (Task 5 ↔ §TimelineProvider model); Weekly goal 4 families + deep link + a11y (Task 6 ↔ §Widget surface); Last ride 3 families + empty state + deep link + a11y (Task 7 ↔ §Widget surface, §Empty state); signed sim verification at every family + update path + StandBy boundary (Task 8 ↔ §Testing); ROADMAP (Task 9 ↔ §Rough task order 8). CI-safety holds: only Tasks 1–2 add package code (Foundation + AuraCore/AuraKit models, no WidgetKit), Tasks 3–7 are app/extension only.

**Placeholder scan:** no TBD/TODO; every code step shows full code; every command names its expected result.

**Type consistency:** `WidgetSnapshot.make(summaries:goalMeters:units:now:calendar:)`, `weekReset()`, `Week.fraction`/`percent`, `WidgetSnapshotStore(directory:)`/`appGroup()`/`read()`/`write(_:)`, `AppGroup.identifier`, `WidgetRefresh.reload(rideStore:settings:now:)`, `SnapshotEntry`/`SnapshotProvider`, the two widget kinds (`app.aura.widgets.weeklyGoal`/`lastRide`), and the helper names (`Date.widgetWeekday`, `LastRide.kindCaption`/`movingTimeText`, `WidgetStat`) are used identically across tasks. Deep links use the existing `aura://plan` / `aura://history` / `aura://ride` routes only.
