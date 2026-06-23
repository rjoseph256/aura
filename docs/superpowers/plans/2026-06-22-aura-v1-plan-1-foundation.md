# Aura v1 — Plan 1: Foundation (`AuraCore`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `AuraCore`, a pure-Swift package containing all of Aura's framework-independent domain logic — models, ride-statistics math, unit conversion, the swappable routing abstraction, and a GPX-playback harness — fully covered by unit tests runnable with `swift test`.

**Architecture:** A standalone Swift Package with zero Apple-UI dependencies (no SwiftUI/MapKit/Mapbox). Domain types use a local `Coordinate`/`TrackPoint` model rather than `CoreLocation`, so the package compiles and tests on macOS via `swift test` and stays decoupled from any map vendor. Later plans (app target, Mapbox adapter) depend on this package and adapt `CLLocation` ⇄ `TrackPoint` at the boundary.

**Tech Stack:** Swift 5.10+, Swift Package Manager, XCTest. No third-party dependencies in this plan.

**Spec:** `docs/superpowers/specs/2026-06-22-aura-cycling-app-v1-design.md`

**This is Plan 1 of 4** (see spec / brainstorm summary). It produces a tested library, not a runnable app — that arrives in Plan 2.

---

## File Structure

```
biking-app/
  AuraCore/
    Package.swift
    Sources/AuraCore/
      Geo/Coordinate.swift            # Coordinate value type + haversine distance
      Geo/TrackPoint.swift            # A recorded GPS sample (coord + elevation + time)
      Stats/RideStats.swift           # RideStats result type
      Stats/RideStatsCalculator.swift # Pure functions: distance, speed, moving time, elevation gain
      Units/UnitConverter.swift       # m/s↔mph, m↔mi, m↔ft
      Models/Place.swift              # Saved/search destination
      Models/Route.swift              # A planned route + profile label
      Models/Ride.swift               # A recorded ride
      Routing/RouteRequest.swift      # Routing query
      Routing/RoutingProvider.swift   # Protocol (the swappable interface) + MockRoutingProvider
      Routing/RouteRanker.swift       # Labels candidates as mostPaths/fastest/flattest
      Playback/GPXTrack.swift         # Parsed GPX track
      Playback/GPXParser.swift        # XML → GPXTrack
      Playback/GPXLocationPlayer.swift# Deterministic playback schedule
    Tests/AuraCoreTests/
      GeoTests.swift
      RideStatsCalculatorTests.swift
      UnitConverterTests.swift
      ModelCodableTests.swift
      RouteRankerTests.swift
      RoutingProviderTests.swift
      GPXParserTests.swift
      GPXLocationPlayerTests.swift
```

**Responsibilities:** each file owns one concept. Stats math is split from the result type; routing protocol is split from the ranking logic; GPX parsing is split from playback scheduling. All are individually testable.

---

## Prerequisites (one-time, before Task 1)

- [ ] **Confirm toolchain:** `swift --version` reports Swift 5.10 or newer (Xcode 16+ recommended). Run: `swift --version`.
- [ ] **No accounts/tokens needed for Plan 1.** (Mapbox account + access token are required starting in Plan 2 — not here.)
- [ ] Work happens inside the existing repo at `biking-app/` on a feature branch: `git checkout -b plan-1-foundation`.

---

## Task 1: Package skeleton + `Coordinate` with haversine distance

**Files:**
- Create: `AuraCore/Package.swift`
- Create: `AuraCore/Sources/AuraCore/Geo/Coordinate.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GeoTests.swift`

- [ ] **Step 1: Create the package manifest**

`AuraCore/Package.swift`:
```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AuraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AuraCore", targets: ["AuraCore"]),
    ],
    targets: [
        .target(name: "AuraCore"),
        .testTarget(name: "AuraCoreTests", dependencies: ["AuraCore"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

`AuraCore/Tests/AuraCoreTests/GeoTests.swift`:
```swift
import XCTest
@testable import AuraCore

final class GeoTests: XCTestCase {
    func test_distance_betweenTwoKnownPoints_isAccurateWithinOnePercent() {
        // ~1.5 km apart in Pittsburgh (Point State Park → PNC Park area)
        let a = Coordinate(latitude: 40.4417, longitude: -80.0098)
        let b = Coordinate(latitude: 40.4469, longitude: -80.0057)
        let meters = Geo.distance(a, b)
        XCTAssertEqual(meters, 645, accuracy: 645 * 0.02) // within 2%
    }

    func test_distance_betweenIdenticalPoints_isZero() {
        let a = Coordinate(latitude: 40.44, longitude: -80.0)
        XCTAssertEqual(Geo.distance(a, a), 0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter GeoTests`
Expected: FAIL — `Coordinate`/`Geo` not defined (compile error).

- [ ] **Step 4: Write minimal implementation**

`AuraCore/Sources/AuraCore/Geo/Coordinate.swift`:
```swift
import Foundation

public struct Coordinate: Equatable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Geo {
    static let earthRadiusMeters = 6_371_000.0

    /// Great-circle distance in meters (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter GeoTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Package.swift AuraCore/Sources/AuraCore/Geo/Coordinate.swift AuraCore/Tests/AuraCoreTests/GeoTests.swift
git commit -m "feat(core): AuraCore package + Coordinate haversine distance"
```

---

## Task 2: `TrackPoint` + ride-stats engine (distance, speed, moving time, elevation gain)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Geo/TrackPoint.swift`
- Create: `AuraCore/Sources/AuraCore/Stats/RideStats.swift`
- Create: `AuraCore/Sources/AuraCore/Stats/RideStatsCalculator.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideStatsCalculatorTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/RideStatsCalculatorTests.swift`:
```swift
import XCTest
@testable import AuraCore

final class RideStatsCalculatorTests: XCTestCase {
    private func pt(_ lat: Double, _ lon: Double, ele: Double, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: ele,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    func test_emptyOrSinglePoint_yieldsZeroStats() {
        XCTAssertEqual(RideStatsCalculator.stats(from: []), .zero)
        let single = [pt(40.44, -80.0, ele: 250, t: 0)]
        XCTAssertEqual(RideStatsCalculator.stats(from: single), .zero)
    }

    func test_distanceAndElevationGain_accumulateOverSegments() {
        let track = [
            pt(40.4400, -80.0000, ele: 250, t: 0),
            pt(40.4410, -80.0000, ele: 255, t: 20),   // climb +5
            pt(40.4420, -80.0000, ele: 252, t: 40),   // descent (ignored for gain)
            pt(40.4430, -80.0000, ele: 258, t: 60),   // climb +6
        ]
        let s = RideStatsCalculator.stats(from: track)
        // Each 0.001° latitude ≈ 111 m → ~333 m total
        XCTAssertEqual(s.distanceMeters, 333, accuracy: 8)
        XCTAssertEqual(s.elevationGainMeters, 11, accuracy: 0.001) // 5 + 6
    }

    func test_movingTimeExcludesStoppedSegments_andComputesAverageSpeed() {
        let track = [
            pt(40.4400, -80.0000, ele: 250, t: 0),
            pt(40.4410, -80.0000, ele: 250, t: 20),   // ~111 m in 20 s → ~5.5 m/s (moving)
            pt(40.4410, -80.0000, ele: 250, t: 320),  // 0 m in 300 s → stopped (excluded)
            pt(40.4420, -80.0000, ele: 250, t: 340),  // ~111 m in 20 s → moving
        ]
        let s = RideStatsCalculator.stats(from: track)
        XCTAssertEqual(s.movingTimeSeconds, 40, accuracy: 0.001)        // 20 + 20, stop excluded
        XCTAssertGreaterThan(s.maxSpeedMetersPerSecond, 5.0)
        // avg = distance(~222 m) / movingTime(40 s) ≈ 5.55 m/s
        XCTAssertEqual(s.averageSpeedMetersPerSecond, 222.0 / 40.0, accuracy: 0.3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RideStatsCalculatorTests`
Expected: FAIL — `TrackPoint` / `RideStats` / `RideStatsCalculator` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraCore/Geo/TrackPoint.swift`:
```swift
import Foundation

public struct TrackPoint: Equatable, Codable, Sendable {
    public var coordinate: Coordinate
    public var elevation: Double?   // meters above sea level
    public var timestamp: Date

    public init(coordinate: Coordinate, elevation: Double?, timestamp: Date) {
        self.coordinate = coordinate
        self.elevation = elevation
        self.timestamp = timestamp
    }
}
```

`AuraCore/Sources/AuraCore/Stats/RideStats.swift`:
```swift
public struct RideStats: Equatable, Codable, Sendable {
    public var distanceMeters: Double
    public var movingTimeSeconds: Double
    public var averageSpeedMetersPerSecond: Double
    public var maxSpeedMetersPerSecond: Double
    public var elevationGainMeters: Double

    public init(distanceMeters: Double, movingTimeSeconds: Double,
                averageSpeedMetersPerSecond: Double, maxSpeedMetersPerSecond: Double,
                elevationGainMeters: Double) {
        self.distanceMeters = distanceMeters
        self.movingTimeSeconds = movingTimeSeconds
        self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
        self.maxSpeedMetersPerSecond = maxSpeedMetersPerSecond
        self.elevationGainMeters = elevationGainMeters
    }

    public static let zero = RideStats(distanceMeters: 0, movingTimeSeconds: 0,
                                       averageSpeedMetersPerSecond: 0,
                                       maxSpeedMetersPerSecond: 0, elevationGainMeters: 0)
}
```

`AuraCore/Sources/AuraCore/Stats/RideStatsCalculator.swift`:
```swift
import Foundation

public enum RideStatsCalculator {
    /// Computes ride statistics from an ordered list of GPS samples.
    /// - movingSpeedThreshold: segments slower than this (m/s) are treated as "stopped".
    /// - elevationNoiseThreshold: positive elevation deltas smaller than this (m) are ignored as GPS noise.
    public static func stats(from points: [TrackPoint],
                             movingSpeedThreshold: Double = 0.5,
                             elevationNoiseThreshold: Double = 1.0) -> RideStats {
        guard points.count >= 2 else { return .zero }

        var distance = 0.0
        var movingTime = 0.0
        var maxSpeed = 0.0
        var elevationGain = 0.0

        for i in 1..<points.count {
            let prev = points[i - 1], curr = points[i]
            let segDistance = Geo.distance(prev.coordinate, curr.coordinate)
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            distance += segDistance

            if dt > 0 {
                let speed = segDistance / dt
                if speed >= movingSpeedThreshold {
                    movingTime += dt
                    maxSpeed = max(maxSpeed, speed)
                }
            }

            if let e1 = prev.elevation, let e2 = curr.elevation {
                let delta = e2 - e1
                if delta >= elevationNoiseThreshold { elevationGain += delta }
            }
        }

        let avgSpeed = movingTime > 0 ? distance / movingTime : 0
        return RideStats(distanceMeters: distance,
                         movingTimeSeconds: movingTime,
                         averageSpeedMetersPerSecond: avgSpeed,
                         maxSpeedMetersPerSecond: maxSpeed,
                         elevationGainMeters: elevationGain)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RideStatsCalculatorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Geo/TrackPoint.swift AuraCore/Sources/AuraCore/Stats AuraCore/Tests/AuraCoreTests/RideStatsCalculatorTests.swift
git commit -m "feat(core): ride-stats engine (distance, moving time, speed, elevation gain)"
```

---

## Task 3: Unit conversion (imperial)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Units/UnitConverter.swift`
- Test: `AuraCore/Tests/AuraCoreTests/UnitConverterTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/UnitConverterTests.swift`:
```swift
import XCTest
@testable import AuraCore

final class UnitConverterTests: XCTestCase {
    func test_metersPerSecondToMPH() {
        XCTAssertEqual(UnitConverter.mph(fromMetersPerSecond: 10), 22.369, accuracy: 0.001)
        XCTAssertEqual(UnitConverter.mph(fromMetersPerSecond: 0), 0, accuracy: 0.0001)
    }
    func test_metersToMiles() {
        XCTAssertEqual(UnitConverter.miles(fromMeters: 1609.344), 1.0, accuracy: 0.0001)
    }
    func test_metersToFeet() {
        XCTAssertEqual(UnitConverter.feet(fromMeters: 100), 328.084, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter UnitConverterTests`
Expected: FAIL — `UnitConverter` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraCore/Units/UnitConverter.swift`:
```swift
public enum UnitConverter {
    public static func mph(fromMetersPerSecond v: Double) -> Double { v * 2.2369362920544 }
    public static func miles(fromMeters m: Double) -> Double { m / 1609.344 }
    public static func feet(fromMeters m: Double) -> Double { m * 3.280839895013123 }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter UnitConverterTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Units AuraCore/Tests/AuraCoreTests/UnitConverterTests.swift
git commit -m "feat(core): imperial unit conversion"
```

---

## Task 4: Domain models (`Place`, `Route`, `Ride`) + Codable round-trip

**Files:**
- Create: `AuraCore/Sources/AuraCore/Models/Place.swift`
- Create: `AuraCore/Sources/AuraCore/Models/Route.swift`
- Create: `AuraCore/Sources/AuraCore/Models/Ride.swift`
- Test: `AuraCore/Tests/AuraCoreTests/ModelCodableTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/ModelCodableTests.swift`:
```swift
import XCTest
@testable import AuraCore

final class ModelCodableTests: XCTestCase {
    func test_ride_encodesAndDecodesLosslessly() throws {
        let ride = Ride(
            id: UUID(),
            kind: .freeRide,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            track: [TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0),
                               elevation: 250, timestamp: Date(timeIntervalSince1970: 1_000))],
            stats: .zero,
            routeId: nil,
            destinationPlaceId: nil
        )
        let data = try JSONEncoder().encode(ride)
        let decoded = try JSONDecoder().decode(Ride.self, from: data)
        XCTAssertEqual(decoded, ride)
    }

    func test_route_profileEnum_roundTrips() throws {
        let route = Route(id: UUID(), origin: .init(latitude: 40.44, longitude: -80.0),
                          destination: .init(latitude: 40.45, longitude: -80.01),
                          waypoints: [], geometry: [], profile: .flattest,
                          distanceMeters: 1200, estimatedDurationSeconds: 420, elevationGainMeters: 30)
        let decoded = try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(decoded.profile, .flattest)
        XCTAssertEqual(decoded, route)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter ModelCodableTests`
Expected: FAIL — models undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraCore/Models/Place.swift`:
```swift
import Foundation

public struct Place: Identifiable, Codable, Equatable, Sendable {
    public enum Category: String, Codable, Sendable {
        case brewery, trailhead, address, custom
    }
    public var id: UUID
    public var name: String
    public var coordinate: Coordinate
    public var category: Category
    public var isSaved: Bool

    public init(id: UUID = UUID(), name: String, coordinate: Coordinate,
                category: Category, isSaved: Bool = false) {
        self.id = id; self.name = name; self.coordinate = coordinate
        self.category = category; self.isSaved = isSaved
    }
}
```

`AuraCore/Sources/AuraCore/Models/Route.swift`:
```swift
import Foundation

public struct Route: Identifiable, Codable, Equatable, Sendable {
    public enum Profile: String, Codable, Sendable {
        case mostPaths, fastest, flattest
    }
    public var id: UUID
    public var origin: Coordinate
    public var destination: Coordinate
    public var waypoints: [Coordinate]
    public var geometry: [Coordinate]
    public var profile: Profile
    public var distanceMeters: Double
    public var estimatedDurationSeconds: Double
    public var elevationGainMeters: Double

    public init(id: UUID = UUID(), origin: Coordinate, destination: Coordinate,
                waypoints: [Coordinate], geometry: [Coordinate], profile: Profile,
                distanceMeters: Double, estimatedDurationSeconds: Double, elevationGainMeters: Double) {
        self.id = id; self.origin = origin; self.destination = destination
        self.waypoints = waypoints; self.geometry = geometry; self.profile = profile
        self.distanceMeters = distanceMeters
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.elevationGainMeters = elevationGainMeters
    }
}
```

`AuraCore/Sources/AuraCore/Models/Ride.swift`:
```swift
import Foundation

public struct Ride: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case navigate, freeRide }
    public var id: UUID
    public var kind: Kind
    public var startedAt: Date
    public var endedAt: Date?
    public var track: [TrackPoint]
    public var stats: RideStats?
    public var routeId: UUID?
    public var destinationPlaceId: UUID?

    public init(id: UUID = UUID(), kind: Kind, startedAt: Date, endedAt: Date?,
                track: [TrackPoint], stats: RideStats?, routeId: UUID?, destinationPlaceId: UUID?) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.track = track; self.stats = stats; self.routeId = routeId
        self.destinationPlaceId = destinationPlaceId
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter ModelCodableTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models AuraCore/Tests/AuraCoreTests/ModelCodableTests.swift
git commit -m "feat(core): Place/Route/Ride domain models"
```

---

## Task 5: Routing abstraction (`RoutingProvider`, `RouteRequest`, `MockRoutingProvider`)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Routing/RouteRequest.swift`
- Create: `AuraCore/Sources/AuraCore/Routing/RoutingProvider.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RoutingProviderTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/RoutingProviderTests.swift`:
```swift
import XCTest
@testable import AuraCore

final class RoutingProviderTests: XCTestCase {
    func test_mockProvider_returnsConfiguredRoutes() async throws {
        let route = Route(origin: .init(latitude: 40.44, longitude: -80.0),
                          destination: .init(latitude: 40.45, longitude: -80.01),
                          waypoints: [], geometry: [], profile: .fastest,
                          distanceMeters: 1000, estimatedDurationSeconds: 300, elevationGainMeters: 10)
        let provider: RoutingProvider = MockRoutingProvider(result: [route])
        let request = RouteRequest(origin: route.origin, destination: route.destination, waypoints: [])
        let routes = try await provider.routes(for: request)
        XCTAssertEqual(routes, [route])
    }

    func test_mockProvider_canBeConfiguredToThrow() async {
        struct Boom: Error {}
        let provider: RoutingProvider = MockRoutingProvider(error: Boom())
        let request = RouteRequest(origin: .init(latitude: 0, longitude: 0),
                                   destination: .init(latitude: 1, longitude: 1), waypoints: [])
        do { _ = try await provider.routes(for: request); XCTFail("should throw") }
        catch { /* expected */ }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RoutingProviderTests`
Expected: FAIL — routing types undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraCore/Routing/RouteRequest.swift`:
```swift
public struct RouteRequest: Equatable, Sendable {
    public var origin: Coordinate
    public var destination: Coordinate
    public var waypoints: [Coordinate]

    public init(origin: Coordinate, destination: Coordinate, waypoints: [Coordinate] = []) {
        self.origin = origin; self.destination = destination; self.waypoints = waypoints
    }
}
```

`AuraCore/Sources/AuraCore/Routing/RoutingProvider.swift`:
```swift
/// The swappable routing interface. v1 ships a Mapbox-backed implementation (Plan 3);
/// a self-hosted Valhalla/BRouter implementation can replace it without touching callers.
public protocol RoutingProvider: Sendable {
    func routes(for request: RouteRequest) async throws -> [Route]
}

/// Test/dev double.
public struct MockRoutingProvider: RoutingProvider {
    public var result: [Route]
    public var error: Error?

    public init(result: [Route] = [], error: Error? = nil) {
        self.result = result; self.error = error
    }

    public func routes(for request: RouteRequest) async throws -> [Route] {
        if let error { throw error }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RoutingProviderTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Routing/RouteRequest.swift AuraCore/Sources/AuraCore/Routing/RoutingProvider.swift AuraCore/Tests/AuraCoreTests/RoutingProviderTests.swift
git commit -m "feat(core): RoutingProvider abstraction + mock"
```

---

## Task 6: `RouteRanker` — label candidates as Most paths / Fastest / Flattest

This implements the spec's §3 v1 approach: a routing backend returns raw alternatives; we rank and label them post-hoc.

**Files:**
- Create: `AuraCore/Sources/AuraCore/Routing/RouteRanker.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RouteRankerTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/RouteRankerTests.swift`:
```swift
import XCTest
@testable import AuraCore

final class RouteRankerTests: XCTestCase {
    private let origin = Coordinate(latitude: 40.44, longitude: -80.0)
    private let dest = Coordinate(latitude: 40.45, longitude: -80.01)

    private func candidate(dur: Double, ele: Double, offRoad: Double) -> CandidateRoute {
        CandidateRoute(geometry: [origin, dest], distanceMeters: 1000,
                       estimatedDurationSeconds: dur, elevationGainMeters: ele, offRoadFraction: offRoad)
    }

    func test_labelsThreeDistinctWinners() {
        let fast = candidate(dur: 200, ele: 80, offRoad: 0.1)   // fastest
        let flat = candidate(dur: 400, ele: 5,  offRoad: 0.2)   // flattest
        let paths = candidate(dur: 350, ele: 60, offRoad: 0.9)  // most paths
        let result = RouteRanker.label(origin: origin, destination: dest,
                                       candidates: [fast, flat, paths])
        let byProfile = Dictionary(uniqueKeysWithValues: result.map { ($0.profile, $0) })
        XCTAssertEqual(byProfile[.fastest]?.estimatedDurationSeconds, 200)
        XCTAssertEqual(byProfile[.flattest]?.elevationGainMeters, 5)
        XCTAssertEqual(byProfile[.mostPaths]?.geometry, [origin, dest])
        XCTAssertEqual(result.count, 3)
    }

    func test_dedupesWhenOneCandidateWinsMultipleCriteria() {
        // A single candidate that is fastest AND flattest AND most-paths → returned once.
        let allRounder = candidate(dur: 100, ele: 1, offRoad: 0.99)
        let worse = candidate(dur: 500, ele: 90, offRoad: 0.05)
        let result = RouteRanker.label(origin: origin, destination: dest,
                                       candidates: [allRounder, worse])
        XCTAssertEqual(result.count, 1)
        // Highest-priority label wins: mostPaths > flattest > fastest
        XCTAssertEqual(result.first?.profile, .mostPaths)
    }

    func test_emptyCandidates_returnsEmpty() {
        XCTAssertTrue(RouteRanker.label(origin: origin, destination: dest, candidates: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RouteRankerTests`
Expected: FAIL — `CandidateRoute` / `RouteRanker` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraCore/Routing/RouteRanker.swift`:
```swift
import Foundation

/// A raw routing alternative before it has been labeled with a user-facing profile.
public struct CandidateRoute: Equatable, Sendable {
    public var geometry: [Coordinate]
    public var distanceMeters: Double
    public var estimatedDurationSeconds: Double
    public var elevationGainMeters: Double
    public var offRoadFraction: Double   // 0...1 — share of the route on paths/trails

    public init(geometry: [Coordinate], distanceMeters: Double, estimatedDurationSeconds: Double,
                elevationGainMeters: Double, offRoadFraction: Double) {
        self.geometry = geometry; self.distanceMeters = distanceMeters
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.elevationGainMeters = elevationGainMeters; self.offRoadFraction = offRoadFraction
    }
}

public enum RouteRanker {
    /// Picks the best candidate for each profile and returns up to 3 distinct labeled Routes.
    /// Label priority when one candidate wins multiple criteria: mostPaths > flattest > fastest.
    public static func label(origin: Coordinate, destination: Coordinate,
                             candidates: [CandidateRoute]) -> [Route] {
        guard !candidates.isEmpty else { return [] }

        // (profile, winning index) in priority order.
        let winners: [(Route.Profile, Int)] = [
            (.mostPaths, indexOfMax(candidates) { $0.offRoadFraction }),
            (.flattest, indexOfMin(candidates) { $0.elevationGainMeters }),
            (.fastest, indexOfMin(candidates) { $0.estimatedDurationSeconds }),
        ]

        var usedIndices = Set<Int>()
        var routes: [Route] = []
        for (profile, idx) in winners where !usedIndices.contains(idx) {
            usedIndices.insert(idx)
            let c = candidates[idx]
            routes.append(Route(origin: origin, destination: destination, waypoints: [],
                                geometry: c.geometry, profile: profile,
                                distanceMeters: c.distanceMeters,
                                estimatedDurationSeconds: c.estimatedDurationSeconds,
                                elevationGainMeters: c.elevationGainMeters))
        }
        return routes
    }

    private static func indexOfMin(_ items: [CandidateRoute], _ key: (CandidateRoute) -> Double) -> Int {
        var best = 0
        for i in items.indices where key(items[i]) < key(items[best]) { best = i }
        return best
    }
    private static func indexOfMax(_ items: [CandidateRoute], _ key: (CandidateRoute) -> Double) -> Int {
        var best = 0
        for i in items.indices where key(items[i]) > key(items[best]) { best = i }
        return best
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RouteRankerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Routing/RouteRanker.swift AuraCore/Tests/AuraCoreTests/RouteRankerTests.swift
git commit -m "feat(core): RouteRanker labels candidates as mostPaths/fastest/flattest"
```

---

## Task 7: GPX parser

**Files:**
- Create: `AuraCore/Sources/AuraCore/Playback/GPXTrack.swift`
- Create: `AuraCore/Sources/AuraCore/Playback/GPXParser.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GPXParserTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/GPXParserTests.swift`:
```swift
import XCTest
@testable import AuraCore

final class GPXParserTests: XCTestCase {
    private let sample = """
    <?xml version="1.0"?>
    <gpx version="1.1"><trk><trkseg>
      <trkpt lat="40.4400" lon="-80.0000"><ele>250.0</ele><time>2026-06-22T14:00:00Z</time></trkpt>
      <trkpt lat="40.4410" lon="-80.0000"><ele>255.0</ele><time>2026-06-22T14:00:20Z</time></trkpt>
    </trkseg></trk></gpx>
    """

    func test_parsesTrackPointsWithElevationAndTime() throws {
        let track = try GPXParser.parse(sample)
        XCTAssertEqual(track.points.count, 2)
        XCTAssertEqual(track.points[0].coordinate.latitude, 40.44, accuracy: 0.0001)
        XCTAssertEqual(track.points[0].coordinate.longitude, -80.0, accuracy: 0.0001)
        XCTAssertEqual(track.points[0].elevation, 250.0)
        XCTAssertEqual(track.points[1].elevation, 255.0)
        XCTAssertEqual(track.points[1].timestamp.timeIntervalSince(track.points[0].timestamp), 20, accuracy: 0.001)
    }

    func test_emptyGPX_yieldsNoPoints() throws {
        let track = try GPXParser.parse("<?xml version=\\"1.0\\"?><gpx></gpx>")
        XCTAssertTrue(track.points.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter GPXParserTests`
Expected: FAIL — `GPXTrack` / `GPXParser` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraCore/Playback/GPXTrack.swift`:
```swift
public struct GPXTrack: Equatable, Sendable {
    public var points: [TrackPoint]
    public init(points: [TrackPoint]) { self.points = points }
}
```

`AuraCore/Sources/AuraCore/Playback/GPXParser.swift`:
```swift
import Foundation

public enum GPXParser {
    public enum ParseError: Error { case invalidXML }

    public static func parse(_ xml: String) throws -> GPXTrack {
        guard let data = xml.data(using: .utf8) else { throw ParseError.invalidXML }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.invalidXML }
        return GPXTrack(points: delegate.points)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var points: [TrackPoint] = []
        private var lat = 0.0, lon = 0.0
        private var ele: Double?
        private var time: Date?
        private var buffer = ""
        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
        }()

        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            buffer = ""
            if el == "trkpt" {
                lat = Double(attrs["lat"] ?? "") ?? 0
                lon = Double(attrs["lon"] ?? "") ?? 0
                ele = nil; time = nil
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { buffer += s }
        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            switch el {
            case "ele": ele = Double(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "time": time = Self.iso.date(from: buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "trkpt":
                points.append(TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                                         elevation: ele, timestamp: time ?? Date(timeIntervalSince1970: 0)))
            default: break
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter GPXParserTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Playback/GPXTrack.swift AuraCore/Sources/AuraCore/Playback/GPXParser.swift AuraCore/Tests/AuraCoreTests/GPXParserTests.swift
git commit -m "feat(core): GPX parser"
```

---

## Task 8: `GPXLocationPlayer` — deterministic playback schedule

Produces relative time offsets for each point so the app (Plan 2) can replay a recorded ride into the location pipeline without physically biking. Kept timing-free (returns a schedule) so it is deterministically testable.

**Files:**
- Create: `AuraCore/Sources/AuraCore/Playback/GPXLocationPlayer.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GPXLocationPlayerTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/GPXLocationPlayerTests.swift`:
```swift
import XCTest
@testable import AuraCore

final class GPXLocationPlayerTests: XCTestCase {
    private func pt(_ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0), elevation: 250,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    func test_scheduleOffsets_areRelativeToFirstPoint() {
        let track = GPXTrack(points: [pt(100), pt(120), pt(180)])
        let schedule = GPXLocationPlayer.schedule(track: track)
        XCTAssertEqual(schedule.map(\\.offset), [0, 20, 80])
    }

    func test_speedMultiplier_compressesOffsets() {
        let track = GPXTrack(points: [pt(0), pt(20), pt(40)])
        let schedule = GPXLocationPlayer.schedule(track: track, speedMultiplier: 2)
        XCTAssertEqual(schedule.map(\\.offset), [0, 10, 20])
    }

    func test_emptyTrack_yieldsEmptySchedule() {
        XCTAssertTrue(GPXLocationPlayer.schedule(track: GPXTrack(points: [])).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter GPXLocationPlayerTests`
Expected: FAIL — `GPXLocationPlayer` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraCore/Playback/GPXLocationPlayer.swift`:
```swift
import Foundation

public enum GPXLocationPlayer {
    public struct ScheduledPoint: Equatable, Sendable {
        public var offset: TimeInterval   // seconds after playback start
        public var point: TrackPoint
    }

    /// Maps each track point to a playback offset relative to the first point.
    /// - speedMultiplier: >1 plays back faster (offsets compressed).
    public static func schedule(track: GPXTrack, speedMultiplier: Double = 1) -> [ScheduledPoint] {
        guard let first = track.points.first else { return [] }
        let m = speedMultiplier > 0 ? speedMultiplier : 1
        return track.points.map { p in
            ScheduledPoint(offset: p.timestamp.timeIntervalSince(first.timestamp) / m, point: p)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter GPXLocationPlayerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Playback/GPXLocationPlayer.swift AuraCore/Tests/AuraCoreTests/GPXLocationPlayerTests.swift
git commit -m "feat(core): GPXLocationPlayer playback schedule"
```

---

## Task 9: Full suite green + wrap-up

- [ ] **Step 1: Run the entire test suite**

Run: `cd AuraCore && swift test`
Expected: PASS — all tests across all files (no filter). Confirm 0 failures.

- [ ] **Step 2: Confirm a clean build with warnings surfaced**

Run: `cd AuraCore && swift build -Xswiftc -warnings-as-errors`
Expected: Build succeeds with no warnings. Fix any that appear.

- [ ] **Step 3: Final commit (if anything changed)**

```bash
git add -A
git commit -m "chore(core): Plan 1 foundation complete — AuraCore green" || echo "nothing to commit"
```

---

## Done criteria for Plan 1

- `swift test` passes with the full suite green.
- `AuraCore` exposes: `Coordinate`, `Geo`, `TrackPoint`, `RideStats`, `RideStatsCalculator`, `UnitConverter`, `Place`, `Route`, `Ride`, `RouteRequest`, `RoutingProvider`, `MockRoutingProvider`, `CandidateRoute`, `RouteRanker`, `GPXTrack`, `GPXParser`, `GPXLocationPlayer`.
- No third-party dependencies; no SwiftUI/MapKit/Mapbox imports.
- **Next:** Plan 2 creates the iOS app target, integrates the Mapbox Maps + Navigation SDK, and builds the RIDE-mode HUD (free-ride first) on top of `AuraCore`.
