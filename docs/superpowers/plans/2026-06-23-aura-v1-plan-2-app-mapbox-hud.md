# Aura v1 — Plan 2: App Scaffold + Mapbox + RIDE-mode HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce the first runnable Aura iOS app: a dark "RIDE mode" HUD that records a **free ride** (no destination) over a Mapbox map — live speed, distance, duration, and elevation — drivable both by real GPS and by a bundled GPX simulator for desk testing.

**Architecture:** Adds two layers on top of the pure `AuraCore` package from Plan 1. (1) `AuraKit` — a new CoreLocation-aware Swift target (same package) holding the `LocationStreaming` abstraction, a live and a simulated location provider, and the `@Observable RideRecorder` that turns a stream of `TrackPoint`s into live `RideStats`. (2) The `Aura` iOS app target (generated via XcodeGen) holding SwiftUI views, the Aura theme, and the Mapbox Maps SDK integration. Deterministic logic (`AuraKit`) is fully unit-tested with `swift test`; the map/SwiftUI glue is build-and-run verified.

**Tech Stack:** Swift 5.10+, SwiftUI, Observation, CoreLocation, Mapbox **Maps** SDK v11 (Navigation SDK is added later in Plan 3), XcodeGen, SwiftData (deferred to Plan 4 — not used here), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-22-aura-cycling-app-v1-design.md`
**Depends on:** Plan 1 (`AuraCore`) complete and green.

**This is Plan 2 of 4.** Scope is the **free-ride RIDE HUD only**. Turn-by-turn navigation, route planning/preview, and the Mapbox **Navigation** SDK are Plan 3. Persistent history, settings, and offline maps are Plan 4.

### Notes for implementers
- **Mapbox API drift:** the deep research flagged Mapbox SDK versions/APIs as fast-moving. The map/annotation code below targets Maps SDK **v11** SwiftUI APIs; **verify symbol names against the installed SDK version's docs** before assuming a step is wrong. The *testable* logic in `AuraKit` does not depend on Mapbox and is the source of truth for correctness.
- **HUD visual implementation:** when building the SwiftUI HUD (Tasks 6–7), run the UI work through the design skills per the project's standing instruction — `impeccable` (entry point) and `emil-design-eng` (motion/polish). This plan specifies layout, data, and tokens; those skills guide the craft.
- Keep `AuraCore` pure — all CoreLocation code lives in `AuraKit` or the app.

---

## File Structure

```
biking-app/
  AuraCore/
    Package.swift                          # MODIFY: add AuraKit target + test target
    Sources/AuraKit/
      LocationStreaming.swift              # protocol: AsyncStream<TrackPoint>
      SimulatedLocationProvider.swift      # GPX → timed TrackPoint stream (desk testing)
      LiveLocationProvider.swift           # CLLocationManager → TrackPoint stream
      RideRecorder.swift                   # @Observable: stream → live RideStats
    Tests/AuraKitTests/
      SimulatedLocationProviderTests.swift
      RideRecorderTests.swift
  Aura/                                     # iOS app (XcodeGen-generated project)
    project.yml                            # XcodeGen spec
    Sources/
      AuraApp.swift                        # @main App
      Theme/AuraTheme.swift                # colors + type tokens
      Ride/RideHUDView.swift               # the cockpit (free-ride)
      Ride/RideMapView.swift               # Mapbox map + live track polyline
      Ride/RideSummaryView.swift           # end-of-ride summary (in-memory)
      Ride/SpeedRail.swift                 # glanceable metric rail
    Resources/
      sample-ride-pittsburgh.gpx           # bundled track for the simulator
      Info.plist                           # location usage strings + bg mode
  .mapbox-setup.md                          # token setup notes (gitignored secrets)
```

---

## Prerequisites (one-time, before Task 1)

- [ ] **Xcode 16+ and an iOS 17+ simulator** installed. Confirm: `xcodebuild -version`.
- [ ] **XcodeGen installed:** `brew install xcodegen` then `xcodegen --version`.
- [ ] **Mapbox account + two tokens** (free tier):
  - A **public access token** (`pk.…`) — used at runtime by the app.
  - A **secret download token** (`sk.…`) with scope **`Downloads:Read`** — used by SPM to fetch the SDK.
  - Configure the secret token for SPM in `~/.netrc`:
    ```
    machine api.mapbox.com
    login mapbox
    password sk.YOUR_SECRET_DOWNLOAD_TOKEN
    ```
  - Keep the public token out of git: store it in an untracked `Aura/Resources/MapboxAccessToken` file or an xcconfig (see Task 4). Add both to `.gitignore`.
- [ ] On branch: `git checkout -b plan-2-app-hud` (from the Plan 1 result).

---

## Task 1: `AuraKit` target + `LocationStreaming` + `SimulatedLocationProvider`

**Files:**
- Modify: `AuraCore/Package.swift`
- Create: `AuraCore/Sources/AuraKit/LocationStreaming.swift`
- Create: `AuraCore/Sources/AuraKit/SimulatedLocationProvider.swift`
- Test: `AuraCore/Tests/AuraKitTests/SimulatedLocationProviderTests.swift`

- [ ] **Step 1: Add the `AuraKit` library + test target to the manifest**

Replace `AuraCore/Package.swift` with:
```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AuraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AuraCore", targets: ["AuraCore"]),
        .library(name: "AuraKit", targets: ["AuraKit"]),
    ],
    targets: [
        .target(name: "AuraCore"),
        .testTarget(name: "AuraCoreTests", dependencies: ["AuraCore"]),
        .target(name: "AuraKit", dependencies: ["AuraCore"]),
        .testTarget(name: "AuraKitTests", dependencies: ["AuraKit"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

`AuraCore/Tests/AuraKitTests/SimulatedLocationProviderTests.swift`:
```swift
import XCTest
import AuraCore
@testable import AuraKit

final class SimulatedLocationProviderTests: XCTestCase {
    private func pt(_ lat: Double, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80.0), elevation: 250,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    func test_emitsAllPointsInOrder() async {
        let track = GPXTrack(points: [pt(40.40, t: 0), pt(40.41, t: 10), pt(40.42, t: 20)])
        // Large multiplier => offsets≈0 => negligible sleeps, fast & deterministic content.
        let provider = SimulatedLocationProvider(track: track, speedMultiplier: 100_000)
        var collected: [TrackPoint] = []
        for await p in provider.points() { collected.append(p) }
        XCTAssertEqual(collected, track.points)
    }

    func test_emptyTrack_finishesWithNoPoints() async {
        let provider = SimulatedLocationProvider(track: GPXTrack(points: []))
        var count = 0
        for await _ in provider.points() { count += 1 }
        XCTAssertEqual(count, 0)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter SimulatedLocationProviderTests`
Expected: FAIL — `AuraKit` types undefined.

- [ ] **Step 4: Write minimal implementation**

`AuraCore/Sources/AuraKit/LocationStreaming.swift`:
```swift
import Foundation
import AuraCore

/// Source of GPS samples, expressed as AuraCore `TrackPoint`s.
/// Implementations: `LiveLocationProvider` (CoreLocation) and `SimulatedLocationProvider` (GPX).
public protocol LocationStreaming: AnyObject, Sendable {
    func points() -> AsyncStream<TrackPoint>
    func stop()
}
```

`AuraCore/Sources/AuraKit/SimulatedLocationProvider.swift`:
```swift
import Foundation
import AuraCore

/// Replays a GPX track as a timed stream of TrackPoints. `speedMultiplier > 1` plays faster.
public final class SimulatedLocationProvider: LocationStreaming, @unchecked Sendable {
    private let schedule: [GPXLocationPlayer.ScheduledPoint]
    private var task: Task<Void, Never>?

    public init(track: GPXTrack, speedMultiplier: Double = 1) {
        self.schedule = GPXLocationPlayer.schedule(track: track, speedMultiplier: speedMultiplier)
    }

    public func points() -> AsyncStream<TrackPoint> {
        let schedule = self.schedule
        return AsyncStream { continuation in
            let t = Task {
                var last: TimeInterval = 0
                for sp in schedule {
                    let wait = sp.offset - last
                    if wait > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    }
                    if Task.isCancelled { break }
                    last = sp.offset
                    continuation.yield(sp.point)
                }
                continuation.finish()
            }
            self.task = t
            continuation.onTermination = { _ in t.cancel() }
        }
    }

    public func stop() { task?.cancel() }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter SimulatedLocationProviderTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Package.swift AuraCore/Sources/AuraKit/LocationStreaming.swift AuraCore/Sources/AuraKit/SimulatedLocationProvider.swift AuraCore/Tests/AuraKitTests/SimulatedLocationProviderTests.swift
git commit -m "feat(kit): AuraKit target + LocationStreaming + SimulatedLocationProvider"
```

---

## Task 2: `RideRecorder` — stream → live ride stats (the crown-jewel integration test)

**Files:**
- Create: `AuraCore/Sources/AuraKit/RideRecorder.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideRecorderTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/RideRecorderTests.swift`:
```swift
import XCTest
import AuraCore
@testable import AuraKit

final class RideRecorderTests: XCTestCase {
    private func pt(_ lat: Double, ele: Double, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80.0), elevation: ele,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    func test_recordingPoints_matchesRideStatsCalculator() {
        let points = [
            pt(40.4400, ele: 250, t: 0),
            pt(40.4410, ele: 255, t: 20),
            pt(40.4420, ele: 252, t: 40),
            pt(40.4430, ele: 258, t: 60),
        ]
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        points.forEach { recorder.record($0) }
        XCTAssertEqual(recorder.stats, RideStatsCalculator.stats(from: points))
        XCTAssertEqual(recorder.track, points)
    }

    func test_ignoresPointsWhenNotRecording() {
        let recorder = RideRecorder()
        recorder.record(pt(40.44, ele: 250, t: 0)) // before start
        XCTAssertTrue(recorder.track.isEmpty)
        XCTAssertEqual(recorder.stats, .zero)
    }

    func test_end_returnsRideWithStatsAndEndTime() {
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 100))
        recorder.record(pt(40.44, ele: 250, t: 100))
        recorder.record(pt(40.45, ele: 250, t: 160))
        let ride = recorder.end(at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ride.kind, .freeRide)
        XCTAssertEqual(ride.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(ride.endedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ride.stats, recorder.stats)
        XCTAssertEqual(ride.track.count, 2)
        XCTAssertFalse(recorder.isRecording)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RideRecorderTests`
Expected: FAIL — `RideRecorder` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraKit/RideRecorder.swift`:
```swift
import Foundation
import Observation
import AuraCore

/// Accumulates a live ride from incoming TrackPoints and recomputes stats as it goes.
/// Observable so SwiftUI views update on each new sample.
@Observable
@MainActor
public final class RideRecorder {
    public private(set) var isRecording = false
    public private(set) var track: [TrackPoint] = []
    public private(set) var stats: RideStats = .zero
    public private(set) var startedAt: Date?

    private let kind: Ride.Kind

    public init(kind: Ride.Kind = .freeRide) { self.kind = kind }

    public func start(at date: Date) {
        track = []
        stats = .zero
        startedAt = date
        isRecording = true
    }

    public func record(_ point: TrackPoint) {
        guard isRecording else { return }
        track.append(point)
        stats = RideStatsCalculator.stats(from: track)
    }

    @discardableResult
    public func end(at date: Date) -> Ride {
        isRecording = false
        return Ride(kind: kind, startedAt: startedAt ?? date, endedAt: date,
                    track: track, stats: stats, routeId: nil, destinationPlaceId: nil)
    }
}
```

> Note: `RideRecorder` is `@MainActor`. The test methods call it synchronously; XCTest test methods run on the main actor by default for `@MainActor`-isolated types, so these compile and run. If the toolchain complains, annotate the test class `@MainActor`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RideRecorderTests`
Expected: PASS (3 tests). If you hit main-actor isolation errors, add `@MainActor` to the test class and re-run.

- [ ] **Step 5: Run the full package suite (Plan 1 + Plan 2 logic)**

Run: `cd AuraCore && swift test`
Expected: PASS — all AuraCore + AuraKit tests green.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideRecorder.swift AuraCore/Tests/AuraKitTests/RideRecorderTests.swift
git commit -m "feat(kit): RideRecorder with live stats + end-of-ride Ride"
```

---

## Task 3: XcodeGen app target that builds on the simulator

**Files:**
- Create: `Aura/project.yml`
- Create: `Aura/Sources/AuraApp.swift`
- Create: `Aura/Resources/Info.plist`
- Modify: `.gitignore`

- [ ] **Step 1: Write the XcodeGen spec**

`Aura/project.yml`:
```yaml
name: Aura
options:
  bundleIdPrefix: app.aura
  deploymentTarget:
    iOS: "17.0"
packages:
  AuraCore:
    path: ../AuraCore
targets:
  Aura:
    type: application
    platform: iOS
    sources:
      - Sources
      - Resources
    dependencies:
      - package: AuraCore
        product: AuraCore
      - package: AuraCore
        product: AuraKit
    settings:
      base:
        INFOPLIST_FILE: Resources/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: app.aura.ios
        GENERATE_INFOPLIST_FILE: NO
        TARGETED_DEVICE_FAMILY: "1"
```

- [ ] **Step 2: Minimal Info.plist (location strings added in Task 8)**

`Aura/Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>UILaunchScreen</key>
  <dict/>
</dict>
</plist>
```

- [ ] **Step 3: Minimal app entry**

`Aura/Sources/AuraApp.swift`:
```swift
import SwiftUI

@main
struct AuraApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Aura").font(.largeTitle.bold())
        }
    }
}
```

- [ ] **Step 4: Ignore generated project + secrets**

Append to `.gitignore`:
```
# Xcode (generated by XcodeGen)
Aura/Aura.xcodeproj/
Aura/Resources/MapboxAccessToken
*.xcconfig.local
xcuserdata/
```

- [ ] **Step 5: Generate and build on a simulator**

Run:
```bash
cd Aura && xcodegen generate
xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: `** BUILD SUCCEEDED **`. (Pick any installed simulator name from `xcrun simctl list devices`.)

- [ ] **Step 6: Commit**

```bash
git add Aura/project.yml Aura/Sources/AuraApp.swift Aura/Resources/Info.plist .gitignore
git commit -m "feat(app): XcodeGen app target builds on simulator"
```

---

## Task 4: Integrate Mapbox Maps SDK + render a Pittsburgh map

**Files:**
- Modify: `Aura/project.yml`
- Create: `Aura/Sources/Ride/RideMapView.swift`
- Modify: `Aura/Sources/AuraApp.swift`
- Create: `.mapbox-setup.md`

- [ ] **Step 1: Add the Mapbox Maps SDK package**

In `Aura/project.yml`, add under `packages:`:
```yaml
  MapboxMaps:
    url: https://github.com/mapbox/mapbox-maps-ios.git
    majorVersion: 11.0.0
```
And under the `Aura` target `dependencies:` add:
```yaml
      - package: MapboxMaps
        product: MapboxMaps
```

- [ ] **Step 2: Provide the public access token**

Create `Aura/Resources/MapboxAccessToken` (untracked) containing only your `pk.…` token. Add to `Info.plist`:
```xml
  <key>MBXAccessToken</key>
  <string>$(MAPBOX_ACCESS_TOKEN)</string>
```
…and document in `.mapbox-setup.md` how the token is injected (xcconfig or a build phase reading the token file). For the simplest local path, you may instead hardcode the token via `MapboxOptions.accessToken = "pk.…"` at app launch in DEBUG — but never commit it. Record the chosen approach in `.mapbox-setup.md`.

- [ ] **Step 3: A Mapbox map view that draws a track**

`Aura/Sources/Ride/RideMapView.swift`:
```swift
import SwiftUI
import MapboxMaps
import AuraCore

/// Dark Mapbox map that follows the rider and draws the live track.
/// NOTE: verify these symbols against the installed Mapbox Maps SDK v11 API.
struct RideMapView: View {
    let track: [TrackPoint]

    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)

    var body: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            if track.count > 1 {
                PolylineAnnotationGroup {
                    PolylineAnnotation(lineCoordinates: track.map {
                        CLLocationCoordinate2D(latitude: $0.coordinate.latitude,
                                               longitude: $0.coordinate.longitude)
                    })
                    .lineColor(StyleColor(red: 43, green: 224, blue: 138, alpha: 1)) // Aura route green
                    .lineWidth(6)
                }
            }
        }
        .mapStyle(.dark)
        .ignoresSafeArea()
    }
}
```

- [ ] **Step 4: Show the map from the app entry (temporary), centered on Pittsburgh by default**

Update `Aura/Sources/AuraApp.swift`:
```swift
import SwiftUI
import MapboxMaps

@main
struct AuraApp: App {
    init() {
        // If not using xcconfig injection, set the token here in DEBUG (never commit a real token):
        // MapboxOptions.accessToken = "pk.…"
    }
    var body: some Scene {
        WindowGroup {
            RideMapView(track: [])
        }
    }
}
```

- [ ] **Step 5: Regenerate, build, and run**

Run:
```bash
cd Aura && xcodegen generate
xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Then launch in the simulator (open the project in Xcode and Run, or `xcrun simctl` install/launch).
Expected: BUILD SUCCEEDED; a **dark Mapbox map** renders. Verify no missing-token runtime error in the console.

- [ ] **Step 6: Commit**

```bash
git add Aura/project.yml Aura/Sources/Ride/RideMapView.swift Aura/Sources/AuraApp.swift .mapbox-setup.md
git commit -m "feat(app): Mapbox Maps SDK integrated; dark map renders"
```

---

## Task 5: Aura design tokens

**Files:**
- Create: `Aura/Sources/Theme/AuraTheme.swift`

- [ ] **Step 1: Define the cockpit palette + type tokens**

`Aura/Sources/Theme/AuraTheme.swift`:
```swift
import SwiftUI

enum AuraTheme {
    // Aura brand — aurora on near-black
    static let bg      = Color(red: 0.031, green: 0.035, blue: 0.059) // #08090F
    static let surface = Color(red: 0.055, green: 0.067, blue: 0.086) // panels
    static let cyan    = Color(red: 0.212, green: 0.886, blue: 1.0)   // #36E2FF
    static let violet  = Color(red: 0.482, green: 0.357, blue: 1.0)   // #7B5BFF
    static let pink    = Color(red: 1.0,   green: 0.302, blue: 0.616) // #FF4D9D
    static let route   = Color(red: 0.169, green: 0.878, blue: 0.541) // #2BE08A
    static let text    = Color(white: 0.92)
    static let muted   = Color(white: 0.55)

    static let auroraGradient = LinearGradient(
        colors: [cyan, violet, pink], startPoint: .leading, endPoint: .trailing)

    // Glanceable numerics — large, rounded, high-contrast for sunlight.
    static func heroNumber(_ size: CGFloat = 52) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static let unitLabel = Font.system(size: 11, weight: .bold, design: .rounded)
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Theme/AuraTheme.swift
git commit -m "feat(app): Aura design tokens (cockpit palette + type)"
```

---

## Task 6: RIDE-mode HUD (free-ride) wired to `RideRecorder`

> **Design-skill checkpoint:** implement this view's craft via `impeccable` / `emil-design-eng` per the project instruction. The spec below fixes the data, layout intent, and tokens.

**Files:**
- Create: `Aura/Sources/Ride/SpeedRail.swift`
- Create: `Aura/Sources/Ride/RideHUDView.swift`
- Create: `Aura/Resources/sample-ride-pittsburgh.gpx`
- Modify: `Aura/Sources/AuraApp.swift`

- [ ] **Step 1: Glanceable metric rail**

`Aura/Sources/Ride/SpeedRail.swift`:
```swift
import SwiftUI
import AuraCore

struct SpeedRail: View {
    let stats: RideStats
    let elapsed: TimeInterval

    private func fmt(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.0f", UnitConverter.mph(fromMetersPerSecond: stats.averageSpeedMetersPerSecond)))
                .font(AuraTheme.heroNumber())
                .foregroundStyle(AuraTheme.text)
            Text("MPH").font(AuraTheme.unitLabel).foregroundStyle(AuraTheme.muted)
            HStack(spacing: 12) {
                metric(String(format: "%.1f", UnitConverter.miles(fromMeters: stats.distanceMeters)), "MI")
                metric(fmt(elapsed), "TIME")
                metric(String(format: "%.0f", UnitConverter.feet(fromMeters: stats.elevationGainMeters)), "FT ↑")
            }.padding(.top, 6)
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(AuraTheme.text)
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(AuraTheme.muted)
        }
    }
}
```

- [ ] **Step 2: The HUD container (start/end + map + rail), drivable by any `LocationStreaming`**

`Aura/Sources/Ride/RideHUDView.swift`:
```swift
import SwiftUI
import AuraCore
import AuraKit

struct RideHUDView: View {
    /// Inject a provider: LiveLocationProvider in the app, SimulatedLocationProvider for the demo/sim.
    let makeProvider: () -> LocationStreaming

    @State private var recorder = RideRecorder(kind: .freeRide)
    @State private var provider: LocationStreaming?
    @State private var streamTask: Task<Void, Never>?
    @State private var finishedRide: Ride?
    @State private var startDate: Date?
    @State private var now = Date()

    private var elapsed: TimeInterval {
        guard let startDate else { return 0 }
        return now.timeIntervalSince(startDate)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RideMapView(track: recorder.track)
            SpeedRail(stats: recorder.stats, elapsed: elapsed)
                .padding(.trailing, 14).padding(.bottom, 90)
            controls
        }
        .background(AuraTheme.bg)
        .sheet(item: $finishedRide) { RideSummaryView(ride: $0) }
        .task(id: recorder.isRecording) {
            guard recorder.isRecording else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private var controls: some View {
        Button {
            recorder.isRecording ? endRide() : startRide()
        } label: {
            Text(recorder.isRecording ? "End ride" : "Start free ride")
                .font(.headline).foregroundStyle(.black)
                .padding(.vertical, 14).frame(maxWidth: .infinity)
                .background(recorder.isRecording ? AnyShapeStyle(AuraTheme.pink) : AnyShapeStyle(AuraTheme.auroraGradient),
                            in: Capsule())
        }
        .padding(.horizontal, 24).padding(.bottom, 28)
    }

    private func startRide() {
        let p = makeProvider()
        provider = p
        startDate = Date()
        recorder.start(at: startDate!)
        streamTask = Task {
            for await point in p.points() { recorder.record(point) }
        }
    }

    private func endRide() {
        streamTask?.cancel()
        provider?.stop()
        finishedRide = recorder.end(at: Date())
    }
}
```

- [ ] **Step 3: Bundle a small sample GPX for the simulator**

`Aura/Resources/sample-ride-pittsburgh.gpx` (a short GAP-trail-ish segment; extend as desired):
```xml
<?xml version="1.0"?>
<gpx version="1.1"><trk><trkseg>
  <trkpt lat="40.4290" lon="-79.9959"><ele>234</ele><time>2026-06-23T14:00:00Z</time></trkpt>
  <trkpt lat="40.4301" lon="-79.9962"><ele>235</ele><time>2026-06-23T14:00:15Z</time></trkpt>
  <trkpt lat="40.4313" lon="-79.9965"><ele>237</ele><time>2026-06-23T14:00:30Z</time></trkpt>
  <trkpt lat="40.4325" lon="-79.9968"><ele>236</ele><time>2026-06-23T14:00:45Z</time></trkpt>
  <trkpt lat="40.4337" lon="-79.9971"><ele>239</ele><time>2026-06-23T14:01:00Z</time></trkpt>
</trkseg></trk></gpx>
```

- [ ] **Step 4: Wire the HUD with the simulator as the default provider (live provider arrives in Task 8)**

Update `Aura/Sources/AuraApp.swift` body:
```swift
import SwiftUI
import AuraCore
import AuraKit
import MapboxMaps

@main
struct AuraApp: App {
    var body: some Scene {
        WindowGroup {
            RideHUDView(makeProvider: Self.simulatedProvider)
        }
    }

    /// Loads the bundled GPX and replays it at 10× for a quick desk demo.
    static func simulatedProvider() -> LocationStreaming {
        guard let url = Bundle.main.url(forResource: "sample-ride-pittsburgh", withExtension: "gpx"),
              let xml = try? String(contentsOf: url, encoding: .utf8),
              let track = try? GPXParser.parse(xml) else {
            return SimulatedLocationProvider(track: GPXTrack(points: []))
        }
        return SimulatedLocationProvider(track: track, speedMultiplier: 10)
    }
}
```

- [ ] **Step 5: Generate, build, run, and verify**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Then Run in the simulator. Tap **Start free ride**: the track polyline should draw on the dark map and the speed rail should tick up (speed/distance/time/elevation). Tap **End ride**: the summary sheet appears.
Expected: BUILD SUCCEEDED + the described behavior.

- [ ] **Step 6: Commit**

```bash
git add Aura/Sources/Ride/SpeedRail.swift Aura/Sources/Ride/RideHUDView.swift Aura/Resources/sample-ride-pittsburgh.gpx Aura/Sources/AuraApp.swift
git commit -m "feat(app): free-ride RIDE HUD wired to RideRecorder + GPX simulator"
```

---

## Task 7: End-of-ride summary (in-memory)

**Files:**
- Create: `Aura/Sources/Ride/RideSummaryView.swift`

- [ ] **Step 1: Summary view**

`Aura/Sources/Ride/RideSummaryView.swift`:
```swift
import SwiftUI
import AuraCore

struct RideSummaryView: View {
    let ride: Ride
    @Environment(\.dismiss) private var dismiss

    private var stats: RideStats { ride.stats ?? .zero }
    private var duration: TimeInterval {
        guard let end = ride.endedAt else { return 0 }
        return end.timeIntervalSince(ride.startedAt)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Nice ride").font(.largeTitle.bold()).foregroundStyle(AuraTheme.text)
            HStack(spacing: 26) {
                stat(String(format: "%.1f", UnitConverter.miles(fromMeters: stats.distanceMeters)), "miles")
                stat(String(format: "%d min", Int(duration / 60)), "moving" )
                stat(String(format: "%.0f", UnitConverter.feet(fromMeters: stats.elevationGainMeters)), "ft climbed")
            }
            stat(String(format: "%.1f", UnitConverter.mph(fromMetersPerSecond: stats.maxSpeedMetersPerSecond)), "mph top")
            Button("Done") { dismiss() }
                .font(.headline).foregroundStyle(.black)
                .padding(.vertical, 12).padding(.horizontal, 40)
                .background(AuraTheme.auroraGradient, in: Capsule())
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuraTheme.bg.ignoresSafeArea())
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(AuraTheme.text)
            Text(label).font(.caption).foregroundStyle(AuraTheme.muted)
        }
    }
}
```

- [ ] **Step 2: Build, run, verify the summary sheet shows real numbers after an ended ride**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED; ending a (simulated) ride shows distance/time/climb/top-speed.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(app): end-of-ride summary sheet"
```

---

## Task 8: `LiveLocationProvider` (real GPS) + Info.plist permissions

**Files:**
- Create: `AuraCore/Sources/AuraKit/LiveLocationProvider.swift`
- Modify: `Aura/Resources/Info.plist`
- Modify: `Aura/Sources/AuraApp.swift`

- [ ] **Step 1: Implement the live provider (battery-aware per Apple guidance)**

`AuraCore/Sources/AuraKit/LiveLocationProvider.swift`:
```swift
import Foundation
import CoreLocation
import AuraCore

/// CoreLocation-backed provider. Accuracy is intentionally *not* `best` (battery — see spec §8 / Apple guidance).
public final class LiveLocationProvider: NSObject, LocationStreaming, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: AsyncStream<TrackPoint>.Continuation?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
    }

    public func points() -> AsyncStream<TrackPoint> {
        AsyncStream { continuation in
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.manager.stopUpdatingLocation() }
            }
        }
    }

    public func stop() {
        manager.stopUpdatingLocation()
        continuation?.finish()
        continuation = nil
    }

    public func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        for loc in locs {
            continuation?.yield(TrackPoint(
                coordinate: Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude),
                elevation: loc.altitude,
                timestamp: loc.timestamp))
        }
    }
}
```

- [ ] **Step 2: Add location usage strings + background mode to Info.plist**

Add inside the `Info.plist` `<dict>`:
```xml
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Aura uses your location to navigate and record your ride.</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
  <string>Aura keeps tracking your ride when the screen is off so your route and stats stay accurate.</string>
  <key>UIBackgroundModes</key>
  <array><string>location</string></array>
```

- [ ] **Step 3: Add a simple chooser so the app uses real GPS by default, with a debug "Simulate" path**

Update `AuraApp.swift` to default to `LiveLocationProvider`, keeping the simulator available behind a DEBUG toggle:
```swift
        WindowGroup {
            #if DEBUG
            RideHUDView(makeProvider: { LiveLocationProvider() })
                // To demo without moving, temporarily swap to: RideHUDView(makeProvider: Self.simulatedProvider)
            #else
            RideHUDView(makeProvider: { LiveLocationProvider() })
            #endif
        }
```

- [ ] **Step 4: Build + run; on the simulator use Features ▸ Location ▸ City Bicycle Ride to feed motion**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Then Run; grant location permission; choose the simulator's **City Bicycle Ride** to verify the live path renders and stats accumulate.
Expected: BUILD SUCCEEDED + live track/stats from simulated motion.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/LiveLocationProvider.swift Aura/Resources/Info.plist Aura/Sources/AuraApp.swift
git commit -m "feat(app): real GPS via LiveLocationProvider + location permissions"
```

---

## Task 9: Full green + wrap-up

- [ ] **Step 1: Package tests green**

Run: `cd AuraCore && swift test`
Expected: PASS — all AuraCore + AuraKit tests.

- [ ] **Step 2: App builds clean**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "chore(app): Plan 2 complete — free-ride RIDE HUD over Mapbox" || echo "nothing to commit"
```

---

## Done criteria for Plan 2

- `swift test` green for `AuraCore` + `AuraKit` (including the RideRecorder integration test).
- A runnable iOS app: launch → **Start free ride** → live dark cockpit HUD (Mapbox map + track polyline + speed/distance/time/elevation) → **End ride** → summary.
- Works from both real GPS (`LiveLocationProvider`) and the bundled GPX simulator (`SimulatedLocationProvider`).
- `AuraCore` remains pure; CoreLocation lives only in `AuraKit`/app.
- **Next:** Plan 3 adds the Mapbox **Navigation** SDK, destination search, route preview (Most paths / Fastest / Flattest via `RouteRanker`), and the navigate-mode HUD (the growing turn card).
