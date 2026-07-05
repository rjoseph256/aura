# Explore Nearby Gems — Plan 3: The Detour — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Take me there" CTA and a guided detour that overlays a `.freeRide` ride — routing to a surfaced gem and detaching on arrival — without ever changing `Ride.Kind` (recorder / stats / Live Activity never restart).

**Architecture:** A pure `DetourMachine` state machine in AuraCore drives an `@Observable @MainActor GuidanceController` in AuraKit that orchestrates the existing `GuidanceViewModel` (a fresh one per detour leg), a `DetourRouting` seam, and a `HeadingProviding` seam. `RideSessionCoordinator` holds the controller optionally, forwards location points to it, and detaches it on ride end. App-target concretes wrap Mapbox routing / CoreLocation heading and render the slim overlay.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing (`@Suite`/`@Test`/`#expect`), SwiftUI, MapboxMaps/MapboxNavigationCore (app target only), SwiftPM package `AuraCore` (targets `AuraCore` pure + `AuraKit` seams), app target `Aura`.

## Global Constraints

- **Pure core is timestamp-driven, no `Date()`/timers/`Task.sleep`** in `AuraCore` types (`DetourMachine`, `DetourPhase/Event/Effect`, `HeadingArrow`).
- **Package builds on the macOS host (CI):** any iOS-only CoreLocation API (`CLHeading`, `CLLocationManager.startUpdatingHeading`, `CLBackgroundActivitySession`) MUST be `#if os(iOS)`-guarded, and lives ONLY in the app target — the AuraKit protocols/controller import no CoreLocation.
- **Swift 6 Sendable:** `DetourPhase`, `DetourEvent`, `DetourEffect`, `HeadingArrow`, `Gem`, `TurnCardState`, `Route` are all `Sendable`. Seam protocols crossing to app concretes are `Sendable` where they carry data.
- **Reuse, don't reinvent:** `Geo.distance(_:_:)` for meters, `PeerBearing.heading(from:to:)` for bearing, `GuidanceViewModel` for turn-by-turn, `MapboxRoutingProvider` for routes, `TurnCardView`/`ManeuverIcon` for the banner, `AuraTheme` for styling.
- **No schema change (no V5):** the detour and its route are ephemeral, never persisted.
- **Ride terminal calls are only `finish()`/`cancel()`.** The detour NEVER calls them; `onArrive` detaches.
- **Stop ≠ End Ride:** the detour Stop control is top-slotted, neutral styling (never the pink `.destructive` End Ride), VoiceOver label "Stop detour".
- **Commit after every task.** Tests via the `apple-platform-build-tools:builder` agent (never build inline — preserves context; avoids grandchild sprawl).

Spec: `docs/superpowers/specs/2026-07-05-explore-gems-plan-3-detour-design.md` (incl. Review reconciliation R1–R16).

---

## File structure

**AuraCore (pure):**
- Create `AuraCore/Sources/AuraCore/Gems/Detour/DetourPhase.swift` — phase/event/effect enums + `HeadingArrow`.
- Create `AuraCore/Sources/AuraCore/Gems/Detour/DetourMachine.swift` — pure reducer.
- Modify `AuraCore/Sources/AuraCore/Gems/Gem.swift` — `GemCategory.arrivalRadiusMeters` cafe 30→40.

**AuraKit (seams + controller):**
- Create `AuraCore/Sources/AuraKit/Gems/Detour/DetourSeams.swift` — `DetourRouting`, `HeadingProviding`, `GuidanceControlling`.
- Create `AuraCore/Sources/AuraKit/Gems/Detour/GuidanceController.swift` — the `@Observable` controller.
- Modify `AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift` — `detourActive` predicate arbiter.
- Modify `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` — inject/forward/detach.

**App target (concretes + UI):**
- Create `Aura/Sources/Routing/MapboxDetourRouting.swift`.
- Create `Aura/Sources/Ride/CompassHeadingProvider.swift`.
- Create `Aura/Sources/Ride/DetourOverlay.swift`.
- Modify `Aura/Sources/Routing/MapboxGuidanceSession.swift` — defensive free-drive reset (R1).
- Modify `Aura/Sources/Ride/GemDetailSheet.swift` — CTA.
- Modify `Aura/Sources/Ride/RideMapView.swift` — detour polyline + dim track.
- Modify `Aura/Sources/Ride/RideHUDView.swift` — build controller, wire everything.

**Tests:**
- `AuraCore/Tests/AuraCoreTests/DetourMachineTests.swift`
- `AuraCore/Tests/AuraKitTests/GuidanceControllerTests.swift`
- `AuraCore/Tests/AuraKitTests/GemDiscoveryStoreArbiterTests.swift`
- `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorDetourTests.swift` (or extend existing)
- Modify `AuraCore/Tests/AuraCoreTests/GemTests.swift` — radius expectation.

---

## Task 1: DetourMachine (pure core)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Gems/Detour/DetourPhase.swift`
- Create: `AuraCore/Sources/AuraCore/Gems/Detour/DetourMachine.swift`
- Test: `AuraCore/Tests/AuraCoreTests/DetourMachineTests.swift`

**Interfaces:**
- Produces: `DetourPhase` (`.inactive`/`.routing(Gem)`/`.guiding(Gem)`/`.headingOnly(Gem)`, with `.gem: Gem?`, `.isDetouring: Bool`, `.isGuiding: Bool`); `DetourEvent` (`.request(Gem)`/`.routeReady`/`.routeFailedOffline`/`.networkRecovered`/`.arrived`/`.cancel`/`.retarget(Gem)`); `DetourEffect` (`.startRouting(Gem)`/`.startGuidance(Gem)`/`.startHeadingOnly(Gem)`/`.stopGuidance`/`.stopHeading`/`.confirmArrival(Gem)`/`.detached`); `HeadingArrow(relativeBearingDegrees:straightLineDistanceMeters:)`; `enum DetourMachine { static func reduce(_ phase: DetourPhase, on event: DetourEvent) -> (DetourPhase, [DetourEffect]) }`.

- [ ] **Step 1: Write the types**

Create `AuraCore/Sources/AuraCore/Gems/Detour/DetourPhase.swift`:

```swift
import Foundation

/// The detour is an ephemeral guidance overlay on a `.freeRide` session. This is the
/// pure phase it lives in — decoupled from `Ride.Kind`. See DetourMachine for transitions.
public enum DetourPhase: Equatable, Sendable {
    case inactive
    case routing(Gem)
    case guiding(Gem)
    case headingOnly(Gem)

    /// The gem being detoured to, if any.
    public var gem: Gem? {
        switch self {
        case .inactive: return nil
        case .routing(let g), .guiding(let g), .headingOnly(let g): return g
        }
    }

    /// True whenever a detour is in flight (routing, guiding, or offline heading).
    public var isDetouring: Bool {
        if case .inactive = self { return false }
        return true
    }

    /// True only while actively turn-by-turn guiding (drives the Tier-3 haptic arbiter's
    /// wrist-contention note; card/haptic suppression uses `isDetouring`).
    public var isGuiding: Bool {
        if case .guiding = self { return true }
        return false
    }
}

/// Events fed to `DetourMachine`. Arrival is detected outside the machine (Mapbox event
/// while guiding; straight-line distance while headingOnly) and normalized to `.arrived`.
public enum DetourEvent: Equatable, Sendable {
    case request(Gem)
    case routeReady
    case routeFailedOffline
    case networkRecovered
    case arrived
    case cancel
    case retarget(Gem)
}

/// Side-effect intents the machine emits; the AuraKit controller performs them. All are
/// idempotent by contract (R4): a redundant stop/detach is a harmless no-op.
public enum DetourEffect: Equatable, Sendable {
    case startRouting(Gem)
    case startGuidance(Gem)
    case startHeadingOnly(Gem)
    case stopGuidance
    case stopHeading
    case confirmArrival(Gem)
    case detached
}

/// The offline pointer state: a compass arrow (relative to device heading) + crow-flies
/// distance. NOT turn-by-turn — the overlay labels it "approximate direction" (R14).
public struct HeadingArrow: Equatable, Sendable {
    public var relativeBearingDegrees: Double
    public var straightLineDistanceMeters: Double
    public init(relativeBearingDegrees: Double, straightLineDistanceMeters: Double) {
        self.relativeBearingDegrees = relativeBearingDegrees
        self.straightLineDistanceMeters = straightLineDistanceMeters
    }
}
```

Create `AuraCore/Sources/AuraCore/Gems/Detour/DetourMachine.swift`:

```swift
import Foundation

/// The pure heart of the detour: `(phase, event) -> (phase, effects)`. Deterministic,
/// no `Date()`/timers/IO. Any unlisted (phase, event) pair is a no-op returning
/// `(phase, [])` — including `(inactive, routeReady)` / `(inactive, routeFailedOffline)`,
/// which are reachable ONLY via a stale async route completion after cancel (R2); the
/// controller's generation guard makes them unreachable in practice, and the no-op is the
/// safety net.
public enum DetourMachine {
    public static func reduce(_ phase: DetourPhase, on event: DetourEvent) -> (DetourPhase, [DetourEffect]) {
        switch (phase, event) {
        // Cancel from any phase → inactive, tearing down whatever was live. Idempotent (R4).
        case (_, .cancel):
            return (.inactive, [.stopGuidance, .stopHeading, .detached])

        case (.inactive, .request(let g)):
            return (.routing(g), [.startRouting(g)])

        case (.routing(let g), .routeReady):
            return (.guiding(g), [.startGuidance(g)])

        case (.routing(let g), .routeFailedOffline):
            return (.headingOnly(g), [.startHeadingOnly(g)])

        case (.guiding(let g), .arrived):
            return (.inactive, [.stopGuidance, .confirmArrival(g), .detached])

        case (.headingOnly(let g), .arrived):
            return (.inactive, [.stopHeading, .confirmArrival(g), .detached])

        case (.headingOnly(let g), .networkRecovered):
            return (.routing(g), [.stopHeading, .startRouting(g)])

        // Re-target from any active phase → route to the new gem, dropping the old leg.
        case (.routing, .retarget(let g2)),
             (.guiding, .retarget(let g2)),
             (.headingOnly, .retarget(let g2)):
            return (.routing(g2), [.stopGuidance, .stopHeading, .startRouting(g2)])

        default:
            return (phase, [])
        }
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/DetourMachineTests.swift`:

```swift
import Testing
@testable import AuraCore

@Suite struct DetourMachineTests {
    private func gem(_ id: String) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
            category: .park, tier: .card, source: .curated)
    }

    @Test func requestFromInactiveStartsRouting() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.inactive, on: .request(g))
        #expect(phase == .routing(g))
        #expect(fx == [.startRouting(g)])
    }

    @Test func routeReadyStartsGuiding() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.routing(g), on: .routeReady)
        #expect(phase == .guiding(g))
        #expect(fx == [.startGuidance(g)])
    }

    @Test func routeFailedOfflineFallsBackToHeading() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.routing(g), on: .routeFailedOffline)
        #expect(phase == .headingOnly(g))
        #expect(fx == [.startHeadingOnly(g)])
    }

    @Test func arrivalWhileGuidingDetachesAndConfirms() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.guiding(g), on: .arrived)
        #expect(phase == .inactive)
        #expect(fx == [.stopGuidance, .confirmArrival(g), .detached])
    }

    @Test func arrivalWhileHeadingOnlyDetachesAndConfirms() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.headingOnly(g), on: .arrived)
        #expect(phase == .inactive)
        #expect(fx == [.stopHeading, .confirmArrival(g), .detached])
    }

    @Test func networkRecoveredUpgradesToRouting() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.headingOnly(g), on: .networkRecovered)
        #expect(phase == .routing(g))
        #expect(fx == [.stopHeading, .startRouting(g)])
    }

    @Test func retargetFromGuidingRoutesToNewGem() {
        let g1 = gem("a"); let g2 = gem("b")
        let (phase, fx) = DetourMachine.reduce(.guiding(g1), on: .retarget(g2))
        #expect(phase == .routing(g2))
        #expect(fx == [.stopGuidance, .stopHeading, .startRouting(g2)])
    }

    @Test func cancelFromEveryPhaseDetaches() {
        let g = gem("a")
        for phase in [DetourPhase.inactive, .routing(g), .guiding(g), .headingOnly(g)] {
            let (next, fx) = DetourMachine.reduce(phase, on: .cancel)
            #expect(next == .inactive)
            #expect(fx == [.stopGuidance, .stopHeading, .detached])
        }
    }

    @Test func staleRouteReadyFromInactiveIsNoOp() {
        // Reachable only via a late route completion after cancel (R2). Must not start guiding.
        let (phase, fx) = DetourMachine.reduce(.inactive, on: .routeReady)
        #expect(phase == .inactive)
        #expect(fx.isEmpty)
    }

    @Test func retargetWhileInactiveIsNoOp() {
        let (phase, fx) = DetourMachine.reduce(.inactive, on: .retarget(gem("b")))
        #expect(phase == .inactive)
        #expect(fx.isEmpty)
    }

    @Test func arrivedWhileRoutingIsNoOp() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.routing(g), on: .arrived)
        #expect(phase == .routing(g))
        #expect(fx.isEmpty)
    }
}
```

- [ ] **Step 3: Build & run — verify pass**

Dispatch the builder agent: run the `AuraCore` test suite (`swift test` or the package scheme), filtered to `DetourMachineTests`. Expected: 11 tests pass. (Types written in Step 1 make them green immediately — this is a pure reducer; the "failing" state is only the missing-type compile error if written test-first, which is acceptable to collapse for a pure table.)

- [ ] **Step 4: Commit**

```bash
git add AuraCore/Sources/AuraCore/Gems/Detour AuraCore/Tests/AuraCoreTests/DetourMachineTests.swift
git commit -m "feat(gems): DetourMachine pure state machine for the detour (ROH-59)"
```

---

## Task 2a: GuidanceController — routing/guiding/cancel + stale-completion guard + route cache

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/Detour/DetourSeams.swift`
- Create: `AuraCore/Sources/AuraKit/Gems/Detour/GuidanceController.swift`
- Test: `AuraCore/Tests/AuraKitTests/GuidanceControllerTests.swift`

**Interfaces:**
- Consumes: `DetourMachine`, `DetourPhase/Event/Effect`, `Gem`, `Route`, `Coordinate`, `TrackPoint`, `GuidanceViewModel`, `ScriptedGuidanceSession`, `HapticPlaying`, `DistanceUnits`.
- Produces:
  - `protocol DetourRouting: Sendable { func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route }`
  - `protocol HeadingProviding: Sendable { func headings() -> AsyncStream<Double> }`
  - `protocol GuidanceControlling: AnyObject { @MainActor var isDetouring: Bool { get }; @MainActor var isGuiding: Bool { get }; @MainActor func riderDidUpdate(_ point: TrackPoint); @MainActor func detach() }`
  - `@MainActor @Observable final class GuidanceController: GuidanceControlling` with:
    - `init(makeGuidance: @escaping @MainActor () -> GuidanceViewModel, routing: any DetourRouting, heading: any HeadingProviding, haptics: (any HapticPlaying)? = nil, units: DistanceUnits = .imperial, turnHaptics: Bool = true)`
    - `private(set) var phase: DetourPhase`
    - `private(set) var guidance: GuidanceViewModel?` (turn banner binds to `guidance?.turn`)
    - `private(set) var activeRoute: Route?` (map polyline)
    - `private(set) var headingArrow: HeadingArrow?`
    - `private(set) var arrivalBanner: Gem?`
    - `var destinationGem: Gem? { phase.gem }`
    - `func requestDetour(_ gem: Gem, from origin: Coordinate)`
    - `func retarget(_ gem: Gem, from origin: Coordinate)`
    - `func cancel()`

- [ ] **Step 1: Write the seams**

Create `AuraCore/Sources/AuraKit/Gems/Detour/DetourSeams.swift`:

```swift
import AuraCore

/// Fetches a single-leg cycling route to a gem. App concrete wraps `MapboxRoutingProvider`;
/// a throw (offline / no route) drives the machine's `routeFailedOffline`.
public protocol DetourRouting: Sendable {
    func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route
}

/// Streams the device compass heading in degrees (true north). App concrete wraps CLHeading
/// (`#if os(iOS)`); a non-iOS stub yields nothing. Protocol stays CoreLocation-free (macOS CI).
public protocol HeadingProviding: Sendable {
    func headings() -> AsyncStream<Double>
}

/// The narrow face the coordinator sees — keeps `RideSessionCoordinator` free of the concrete
/// controller and testable with a fake.
public protocol GuidanceControlling: AnyObject {
    @MainActor var isDetouring: Bool { get }
    @MainActor var isGuiding: Bool { get }
    @MainActor func riderDidUpdate(_ point: TrackPoint)
    @MainActor func detach()
}
```

- [ ] **Step 2: Write the controller (routing/guiding half)**

Create `AuraCore/Sources/AuraKit/Gems/Detour/GuidanceController.swift`:

```swift
import AuraCore
import Foundation
import Observation

/// Orchestrates the detour: owns the pure `DetourPhase`, drives a fresh `GuidanceViewModel`
/// per leg (R1), fetches routes through the `DetourRouting` seam, and (Task 2b) falls back to
/// a compass pointer offline. It NEVER ends the ride — `onArrive` detaches. See spec R1–R16.
@MainActor
@Observable
public final class GuidanceController: GuidanceControlling {
    public private(set) var phase: DetourPhase = .inactive
    public private(set) var guidance: GuidanceViewModel?
    public private(set) var activeRoute: Route?
    public private(set) var headingArrow: HeadingArrow?
    public private(set) var arrivalBanner: Gem?
    public var destinationGem: Gem? { phase.gem }

    public var isDetouring: Bool { phase.isDetouring }
    public var isGuiding: Bool { phase.isGuiding }

    @ObservationIgnored private let makeGuidance: @MainActor () -> GuidanceViewModel
    @ObservationIgnored private let routing: any DetourRouting
    @ObservationIgnored private let heading: any HeadingProviding
    @ObservationIgnored private let haptics: (any HapticPlaying)?
    @ObservationIgnored private let units: DistanceUnits
    @ObservationIgnored private let turnHaptics: Bool

    /// Monotonic guard: bumped on every request/retarget/cancel so a late route completion
    /// for an abandoned leg is discarded (R2).
    @ObservationIgnored private var requestGeneration = 0
    /// Route cache keyed by (gem id, origin quantized to ~25 m) so rapid same-spot re-toggles
    /// are free but a since-moved origin refetches (R5).
    @ObservationIgnored private var routeCache: [String: Route] = [:]
    @ObservationIgnored private var headingTask: Task<Void, Never>?   // Task 2b
    @ObservationIgnored private var latestHeading: Double?            // Task 2b
    @ObservationIgnored private var arrivalClearTask: Task<Void, Never>?

    public init(makeGuidance: @escaping @MainActor () -> GuidanceViewModel,
                routing: any DetourRouting,
                heading: any HeadingProviding,
                haptics: (any HapticPlaying)? = nil,
                units: DistanceUnits = .imperial,
                turnHaptics: Bool = true) {
        self.makeGuidance = makeGuidance
        self.routing = routing
        self.heading = heading
        self.haptics = haptics
        self.units = units
        self.turnHaptics = turnHaptics
    }

    // MARK: - Public intents

    public func requestDetour(_ gem: Gem, from origin: Coordinate) {
        feed(.request(gem), origin: origin)
    }

    public func retarget(_ gem: Gem, from origin: Coordinate) {
        // Dedupe: re-targeting the gem already active is a no-op with no visual thrash (R2/skeptic#4).
        if phase.isDetouring, phase.gem?.id == gem.id { return }
        feed(.retarget(gem), origin: origin)
    }

    public func cancel() { feed(.cancel, origin: nil) }
    public func detach() { feed(.cancel, origin: nil) }   // coordinator-facing; identical (no arrival chip)

    // MARK: - Machine plumbing

    private func feed(_ event: DetourEvent, origin: Coordinate?) {
        requestGeneration += 1
        let (next, effects) = DetourMachine.reduce(phase, on: event)
        phase = next
        for effect in effects { apply(effect, origin: origin) }
    }

    /// Feed used by async continuations / location updates that must NOT bump the generation.
    private func feedInternal(_ event: DetourEvent, origin: Coordinate?) {
        let (next, effects) = DetourMachine.reduce(phase, on: event)
        phase = next
        for effect in effects { apply(effect, origin: origin) }
    }

    private func apply(_ effect: DetourEffect, origin: Coordinate?) {
        switch effect {
        case .startRouting(let gem):
            guard let origin else { return }
            fetchRoute(to: gem, from: origin)
        case .startGuidance(let gem):
            startGuidance(to: gem)
        case .startHeadingOnly(let gem):
            startHeadingOnly(to: gem)        // Task 2b
        case .stopGuidance:
            stopGuidance()
        case .stopHeading:
            stopHeading()                    // Task 2b
        case .confirmArrival(let gem):
            confirmArrival(gem)
        case .detached:
            activeRoute = nil
        }
    }

    // MARK: - Routing

    private func cacheKey(_ gemID: String, _ origin: Coordinate) -> String {
        // ~25 m quantization: ~0.00025° lat, longitude scaled by cos(lat).
        let lat = (origin.latitude / 0.00025).rounded()
        let lng = (origin.longitude / 0.00025).rounded()
        return "\(gemID)@\(Int(lat)),\(Int(lng))"
    }

    private func fetchRoute(to gem: Gem, from origin: Coordinate) {
        let gen = requestGeneration
        let key = cacheKey(gem.id, origin)
        if let cached = routeCache[key] {
            activeRoute = cached
            feedInternal(.routeReady, origin: origin)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let route = try await self.routing.route(from: origin, to: gem.coordinate)
                // Stale-completion guard (R2): only apply if still routing to THIS gem, same gen.
                guard gen == self.requestGeneration,
                      case .routing(let current) = self.phase, current.id == gem.id else { return }
                self.routeCache[key] = route
                self.activeRoute = route
                self.feedInternal(.routeReady, origin: origin)
            } catch {
                guard gen == self.requestGeneration,
                      case .routing(let current) = self.phase, current.id == gem.id else { return }
                self.feedInternal(.routeFailedOffline, origin: origin)
            }
        }
    }

    // MARK: - Guiding

    private func startGuidance(to gem: Gem) {
        guard let route = activeRoute else { return }
        let vm = makeGuidance()
        vm.units = units
        vm.haptics = haptics
        vm.hapticsEnabled = turnHaptics
        vm.onArrive = { [weak self] in self?.feedInternal(.arrived, origin: nil) }  // detach, never finish (R9)
        vm.start(route: route)
        guidance = vm
    }

    private func stopGuidance() {
        guidance?.stop()
        guidance = nil
    }

    private func confirmArrival(_ gem: Gem) {
        arrivalBanner = gem
        if let cue = haptics { cue.play(.arrival) }   // soft arrival cue
        arrivalClearTask?.cancel()
        arrivalClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.arrivalBanner?.id == gem.id else { return }
            self.arrivalBanner = nil
        }
    }

    // MARK: - Heading (implemented in Task 2b)

    private func startHeadingOnly(to gem: Gem) { /* Task 2b */ }
    private func stopHeading() { headingTask?.cancel(); headingTask = nil; headingArrow = nil }
    public func riderDidUpdate(_ point: TrackPoint) { /* Task 2b */ }
}
```

> **Note on `haptics.play(.arrival)`:** confirm the `HapticPlaying` API and the available `RideHapticCue` cases (`AuraCore/Sources/AuraCore/Guidance/RideHapticCue.swift`). If there is no `.arrival` case, use the softest existing cue (e.g. the gem-surfaced/approach cue) and leave a `// TODO(ROH-56)` linking the haptic-strength setting. Do not invent an enum case that doesn't exist — read the file first.

- [ ] **Step 3: Write the failing tests**

Create `AuraCore/Tests/AuraKitTests/GuidanceControllerTests.swift`:

```swift
import Testing
import AuraCore
@testable import AuraKit

@Suite @MainActor struct GuidanceControllerTests {
    private func gem(_ id: String, lat: Double = 40.50, lng: Double = -79.99) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: lat, longitude: lng),
            category: .park, tier: .card, source: .curated)
    }
    private let origin = Coordinate(latitude: 40.44, longitude: -79.99)

    private func route(to gem: Gem) -> Route {
        Route(origin: origin, destination: gem.coordinate,
              geometry: [origin, gem.coordinate], profile: .cycling,
              distanceMeters: 1000, estimatedDurationSeconds: 300, elevationGainMeters: 0,
              elevationProfile: [0, 0])
    }

    /// A DetourRouting fake whose result we control, recording call count.
    final class FakeRouting: DetourRouting, @unchecked Sendable {
        var result: Result<Route, Error>
        private(set) var calls = 0
        init(_ result: Result<Route, Error>) { self.result = result }
        func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route {
            calls += 1
            switch result { case .success(let r): return r; case .failure(let e): throw e }
        }
    }
    struct Offline: Error {}
    struct NoHeading: HeadingProviding { func headings() -> AsyncStream<Double> { AsyncStream { $0.finish() } } }

    private func controller(routing: any DetourRouting) -> GuidanceController {
        GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(events: [])) },
            routing: routing, heading: NoHeading())
    }

    @Test func requestFetchesRouteThenGuides() async throws {
        let g = gem("a")
        let c = controller(routing: FakeRouting(.success(route(to: g))))
        c.requestDetour(g, from: origin)
        #expect(c.phase == .routing(g))
        try await Task.sleep(for: .milliseconds(50))   // let the fetch Task resolve
        #expect(c.phase == .guiding(g))
        #expect(c.activeRoute != nil)
        #expect(c.isGuiding)
        #expect(c.isDetouring)
    }

    @Test func cancelBeforeRouteResolvesDiscardsStaleCompletion() async throws {
        let g = gem("a")
        // Routing that resolves successfully but we cancel first → must NOT start guiding (R2).
        let c = controller(routing: FakeRouting(.success(route(to: g))))
        c.requestDetour(g, from: origin)
        c.cancel()                                      // bumps generation
        #expect(c.phase == .inactive)
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.phase == .inactive)                   // stale routeReady ignored
        #expect(c.guidance == nil)
    }

    @Test func offlineRouteFallsBackToHeadingOnly() async throws {
        let g = gem("a")
        let c = controller(routing: FakeRouting(.failure(Offline())))
        c.requestDetour(g, from: origin)
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.phase == .headingOnly(g))
    }

    @Test func routeCacheAvoidsRefetchFromSameOrigin() async throws {
        let g = gem("a")
        let fake = FakeRouting(.success(route(to: g)))
        let c = controller(routing: fake)
        c.requestDetour(g, from: origin)
        try await Task.sleep(for: .milliseconds(50))
        c.cancel()
        c.requestDetour(g, from: origin)                // same gem, same origin
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.calls == 1)                         // second request served from cache
        #expect(c.phase == .guiding(g))
    }

    @Test func arrivalDetachesAndConfirmsWithoutEndingRide() async throws {
        // Scripted session that arrives immediately drives onArrive → detach + confirm.
        let g = gem("a")
        let c = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(events: [.arrivedAtDestination])) },
            routing: FakeRouting(.success(route(to: g))), heading: NoHeading())
        c.requestDetour(g, from: origin)
        try await Task.sleep(for: .milliseconds(80))
        #expect(c.phase == .inactive)                    // detached, ride not ended
        #expect(c.arrivalBanner?.id == "a")              // confirm chip set
        #expect(c.guidance == nil)
    }
}
```

> Confirm `ScriptedGuidanceSession`'s initializer shape by reading `AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift` (it may take `events:` or a builder). Adjust the `makeGuidance` closures to match its real init. Also confirm `Route.init` parameter order against `AuraCore/Sources/AuraCore/Models/Route.swift`.

- [ ] **Step 4: Build & run — verify pass**

Builder agent: run `AuraKitTests` filtered to `GuidanceControllerTests`. Expected: 5 tests pass. Fix any signature drift flagged in the notes above.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Gems/Detour AuraCore/Tests/AuraKitTests/GuidanceControllerTests.swift
git commit -m "feat(gems): GuidanceController routing/guiding + stale-guard + route cache (ROH-59)"
```

---

## Task 2b: GuidanceController — offline headingOnly + riderDidUpdate + network recovery

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Gems/Detour/GuidanceController.swift`
- Test: `AuraCore/Tests/AuraKitTests/GuidanceControllerTests.swift` (add cases)

**Interfaces:**
- Consumes: `Geo.distance(_:_:)`, `PeerBearing.heading(from:to:)`, `HeadingProviding`, `GemCategory.arrivalRadiusMeters`.
- Produces: implemented `startHeadingOnly`, `stopHeading`, `riderDidUpdate`; heading arrow + straight-line arrival + throttled network-recovery retry.

- [ ] **Step 1: Implement the heading half**

Replace the Task-2b stubs in `GuidanceController.swift`:

```swift
    // MARK: - Heading (offline pointer)

    private func startHeadingOnly(to gem: Gem) {
        headingTask?.cancel()
        latestHeading = nil
        headingArrow = HeadingArrow(relativeBearingDegrees: 0,
                                    straightLineDistanceMeters: 0)
        let stream = heading.headings()
        headingTask = Task { [weak self] in
            for await deg in stream {
                guard let self else { return }
                self.latestHeading = deg
                self.recomputeArrow()   // refresh arrow as the device turns
            }
        }
    }

    private func stopHeading() {
        headingTask?.cancel()
        headingTask = nil
        headingArrow = nil
        latestHeading = nil
    }

    /// Recompute the arrow from the last known rider coordinate (via `lastRiderCoordinate`) and heading.
    @ObservationIgnored private var lastRiderCoordinate: Coordinate?
    private func recomputeArrow() {
        guard case .headingOnly(let gem) = phase, let rider = lastRiderCoordinate else { return }
        let distance = Geo.distance(rider, gem.coordinate)
        let bearingToGem = PeerBearing.heading(from: rider, to: gem.coordinate)
        let relative = (bearingToGem - (latestHeading ?? 0)).truncatingRemainder(dividingBy: 360)
        headingArrow = HeadingArrow(relativeBearingDegrees: relative,
                                    straightLineDistanceMeters: distance)
    }

    @ObservationIgnored private var recoveryThrottle = 0

    public func riderDidUpdate(_ point: TrackPoint) {
        lastRiderCoordinate = point.coordinate
        // Snapshot phase (TOCTOU guard, R3): a concurrent transition must not misroute this update.
        switch phase {
        case .headingOnly(let gem):
            let distance = Geo.distance(point.coordinate, gem.coordinate)
            recomputeArrow()
            if distance <= gem.category.arrivalRadiusMeters {
                feedInternal(.arrived, origin: nil)
                return
            }
            // Throttled network-recovery probe: retry routing ~every 8th fix.
            recoveryThrottle += 1
            if recoveryThrottle % 8 == 0 { probeNetworkRecovery(from: point.coordinate, gem: gem) }
        case .inactive, .routing, .guiding:
            break   // Mapbox drives arrival while guiding; nothing to do otherwise.
        }
    }

    private func probeNetworkRecovery(from origin: Coordinate, gem: Gem) {
        let gen = requestGeneration
        Task { [weak self] in
            guard let self else { return }
            guard (try? await self.routing.route(from: origin, to: gem.coordinate)) != nil else { return }
            guard gen == self.requestGeneration,
                  case .headingOnly(let current) = self.phase, current.id == gem.id else { return }
            self.feedInternal(.networkRecovered, origin: origin)
        }
    }
```

> `TrackPoint.coordinate` and `Coordinate` come from AuraCore. Confirm `PeerBearing.heading(from:to:)` returns degrees 0–360 (it does). The `probeNetworkRecovery` re-fetch on success feeds `networkRecovered`, whose `startRouting` effect will re-run `fetchRoute` (which re-awaits and guides). Ensure `startRouting`'s `origin` is threaded: `networkRecovered`'s effect list is `[.stopHeading, .startRouting(gem)]`, and `apply(.startRouting)` needs `origin` — pass the probe origin through `feedInternal(.networkRecovered, origin: origin)`; verify `feedInternal` forwards `origin` to `apply` (it does).

- [ ] **Step 2: Add failing tests**

Append to `GuidanceControllerTests.swift`:

```swift
    /// Heading provider that emits one fixed heading then stays open.
    struct FixedHeading: HeadingProviding {
        let degrees: Double
        func headings() -> AsyncStream<Double> {
            AsyncStream { cont in cont.yield(degrees); /* stays open */ }
        }
    }

    @Test func headingOnlyArrivesWithinRadius() async throws {
        let g = gem("a", lat: 40.4410, lng: -79.9959)   // park → 70 m radius
        let c = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(events: [])) },
            routing: FakeRouting(.failure(Offline())), heading: FixedHeading(degrees: 0))
        c.requestDetour(g, from: Coordinate(latitude: 40.4406, longitude: -79.9959))
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.phase == .headingOnly(g))
        // Feed a fix ~10 m from the gem → inside the 70 m arrival radius.
        c.riderDidUpdate(TrackPoint(coordinate: g.coordinate, timestamp: .init(), speedMetersPerSecond: 3))
        #expect(c.phase == .inactive)
        #expect(c.arrivalBanner?.id == "a")
    }

    @Test func headingOnlyPublishesArrowBeforeArrival() async throws {
        let g = gem("a", lat: 40.55, lng: -79.99)        // far away
        let c = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(events: [])) },
            routing: FakeRouting(.failure(Offline())), heading: FixedHeading(degrees: 0))
        c.requestDetour(g, from: Coordinate(latitude: 40.44, longitude: -79.99))
        try await Task.sleep(for: .milliseconds(50))
        c.riderDidUpdate(TrackPoint(coordinate: Coordinate(latitude: 40.45, longitude: -79.99),
                                    timestamp: .init(), speedMetersPerSecond: 3))
        #expect(c.headingArrow != nil)
        #expect((c.headingArrow?.straightLineDistanceMeters ?? 0) > 100)
    }
```

> Confirm `TrackPoint`'s initializer (params/labels) against `AuraCore/Sources/AuraCore/Models/…`; adjust the literal above to match (it may use `speedMetersPerSecond:` optional or a different label).

- [ ] **Step 3: Build & run — verify pass**

Builder agent: `GuidanceControllerTests` (all 7 now). Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add AuraCore/Sources/AuraKit/Gems/Detour/GuidanceController.swift AuraCore/Tests/AuraKitTests/GuidanceControllerTests.swift
git commit -m "feat(gems): GuidanceController offline heading pointer + arrival + recovery (ROH-59)"
```

---

## Task 3: GemDiscoveryStore arbiter (suppress card + Tier-3 haptic while detouring)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/GemDiscoveryStoreArbiterTests.swift`

**Interfaces:**
- Produces: `GemDiscoveryStore.detourActive: () -> Bool` (settable, default `{ false }`); `update(at:now:)` suppresses `activeCard` + the Tier-3 haptic while `detourActive()` is true, but still records seen + publishes `visiblePins`.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/GemDiscoveryStoreArbiterTests.swift`:

```swift
import Testing
import AuraCore
@testable import AuraKit

@Suite @MainActor struct GemDiscoveryStoreArbiterTests {
    // Reuse the existing GemStoreTestDoubles (provider/seen/haptics fakes) in this target.
    @Test func detourActiveSuppressesCardAndHapticButKeepsPinsAndSeen() async {
        let gem = Gem(id: "curated:x", name: "X",
                      coordinate: Coordinate(latitude: 40.4410, longitude: -79.9959),
                      category: .viewpoint, tier: .cardHaptic, source: .curated)
        let haptics = SpyGemHaptics()                       // from GemStoreTestDoubles
        let store = GemDiscoveryStore(provider: StubProvider(gems: [gem]),
                                      seen: InMemorySeen(), haptics: haptics)
        store.detourActive = { true }                       // simulate an active detour
        await store.load()
        store.update(at: Coordinate(latitude: 40.4406, longitude: -79.9959), now: .init())
        #expect(store.activeCard == nil)                    // card suppressed
        #expect(haptics.playCount == 0)                     // Tier-3 haptic suppressed
        #expect(store.visiblePins.contains { $0.id == "curated:x" })  // pin still shown
        #expect(store.seenIDs.contains("curated:x"))        // still recorded as seen
    }
}
```

> Read `AuraCore/Tests/AuraKitTests/GemStoreTestDoubles.swift` for the actual double names (`StubProvider`/`InMemorySeen`/`SpyGemHaptics` are placeholders — use whatever exists; the shipped `GemDiscoveryStoreActiveTests.swift` shows the real ones). Match its patterns exactly.

- [ ] **Step 2: Run — verify it fails**

Builder agent: `GemDiscoveryStoreArbiterTests`. Expected: FAIL (no `detourActive` member).

- [ ] **Step 3: Implement**

In `GemDiscoveryStore.swift`, add the property near the other stored config:

```swift
    /// Consulted synchronously on the main actor each `update(at:)`. Wired by the HUD to
    /// `{ coordinator.isDetouring }`. While true, the active peek card + Tier-3 gem haptic are
    /// suppressed (turn cues own the cockpit) but pins still render and seen-state is recorded (R7).
    public var detourActive: () -> Bool = { false }
```

Update the surfacing block inside `update(at:now:)`:

```swift
        if let gem = decision.activeSurfacing {
            seenIDs.insert(gem.id)
            seen.markSeen(gem.id, at: now)               // always record as seen
            if !detourActive() {                          // …but stay quiet while detouring
                activeCard = gem
                if gem.tier == .cardHaptic { haptics.playGemSurfaced() }
            }
        }
```

(`visiblePins = decision.visiblePins` above is unchanged — pins always publish.)

- [ ] **Step 4: Build & run — verify pass**

Builder agent: `GemDiscoveryStoreArbiterTests` + the existing `GemDiscoveryStoreActiveTests` (regression). Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift AuraCore/Tests/AuraKitTests/GemDiscoveryStoreArbiterTests.swift
git commit -m "feat(gems): suppress peek card + T3 haptic while detouring, keep pins/seen (ROH-59)"
```

---

## Task 4: RideSessionCoordinator integration (inject / forward / detach)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorDetourTests.swift`

**Interfaces:**
- Consumes: `GuidanceControlling`.
- Produces: `RideSessionCoordinator.init(..., guidance: (any GuidanceControlling)? = nil)`; `var isDetouring: Bool`; `var isGuiding: Bool`; stream loop forwards `guidance?.riderDidUpdate(point)`; `finish()`/`cancel()` call `guidance?.detach()` before `stopStreaming()`.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorDetourTests.swift`:

```swift
import Testing
import AuraCore
@testable import AuraKit

@Suite @MainActor struct RideSessionCoordinatorDetourTests {
    final class SpyGuidance: GuidanceControlling {
        var detourFlag = false
        private(set) var detachCount = 0
        private(set) var updates = 0
        var isDetouring: Bool { detourFlag }
        var isGuiding: Bool { detourFlag }
        func riderDidUpdate(_ point: TrackPoint) { updates += 1 }
        func detach() { detachCount += 1 }
    }

    @Test func finishDetachesGuidance() {
        let spy = SpyGuidance()
        let c = RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: NoopScreen(), activity: NoopActivity(),   // existing coordinator-test doubles
            guidance: spy)
        c.finish()
        #expect(spy.detachCount == 1)
    }

    @Test func cancelDetachesGuidance() {
        let spy = SpyGuidance()
        let c = RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: NoopScreen(), activity: NoopActivity(), guidance: spy)
        c.cancel()
        #expect(spy.detachCount == 1)
    }

    @Test func isDetouringReflectsController() {
        let spy = SpyGuidance()
        let c = RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: NoopScreen(), activity: NoopActivity(), guidance: spy)
        #expect(c.isDetouring == false)
        spy.detourFlag = true
        #expect(c.isDetouring == true)
    }
}
```

> Read the existing coordinator tests (search `RideSessionCoordinator` under `AuraCore/Tests/AuraKitTests/`) for the real screen/activity/location doubles and copy their names. The location-forwarding assertion (`updates > 0`) needs the existing scripted `LocationStreaming` double — add a test mirroring the existing "stream records points" test but asserting `spy.updates > 0` after driving the stream; reuse that test's setup verbatim.

- [ ] **Step 2: Run — verify it fails**

Builder agent. Expected: FAIL (no `guidance:` param).

- [ ] **Step 3: Implement**

In `RideSessionCoordinator.swift`:

1. Add the stored property beside `workout`:
```swift
    @ObservationIgnored private let guidance: (any GuidanceControlling)?
```
2. Add the init param (last, defaulted — backward compatible) and assign:
```swift
    public init(kind: Ride.Kind,
                destinationName: String?,
                screen: any ScreenWakeControlling,
                activity: any RideActivityControlling,
                workout: (any WorkoutWriting)? = nil,
                guidance: (any GuidanceControlling)? = nil) {
        // …existing assignments…
        self.guidance = guidance
    }
```
3. In the stream loop, right after the `discoverySink?.rideDidUpdateLocation(point)` line:
```swift
                self.guidance?.riderDidUpdate(point)
```
4. Add computed arbiter properties near the other public vars:
```swift
    /// True whenever a detour overlay is in flight (drives the gem card/haptic arbiter).
    public var isDetouring: Bool { guidance?.isDetouring ?? false }
    /// True only while turn-by-turn guiding.
    public var isGuiding: Bool { guidance?.isGuiding ?? false }
```
5. In `finish()` and `cancel()`, add as the FIRST line of each (before `stopStreaming()`):
```swift
        guidance?.detach()
```

- [ ] **Step 4: Build & run — verify pass**

Builder agent: the new suite + the full existing coordinator suite (regression). Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift AuraCore/Tests/AuraKitTests/RideSessionCoordinatorDetourTests.swift
git commit -m "feat(gems): coordinator hosts detour controller — forward + detach on end (ROH-59)"
```

---

## Task 5: Arrival-radius product pass (cafe 30 → 40)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Gems/Gem.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GemTests.swift`

**Interfaces:** none new — value change + test update.

- [ ] **Step 1: Update the test expectation (failing first)**

In `GemTests.swift`, find the `arrivalRadiusMeters` assertions and change the cafe case to expect `40`. If none exists, add:

```swift
    @Test func cafeArrivalRadiusIsForgivingForBikes() {
        #expect(GemCategory.cafe.arrivalRadiusMeters == 40)
        #expect(GemCategory.viewpoint.arrivalRadiusMeters == 70)   // unchanged
    }
```

- [ ] **Step 2: Run — verify it fails**

Builder agent: `GemTests`. Expected: FAIL (cafe still 30).

- [ ] **Step 3: Implement**

In `Gem.swift`, `GemCategory.arrivalRadiusMeters`, move `.cafe` from the 30 bucket to a 40 value:

```swift
    public var arrivalRadiusMeters: Double {
        switch self {
        case .mural, .landmark: return 30
        case .cafe: return 40
        case .water, .historic: return 45
        case .park, .viewpoint, .climb: return 70
        }
    }
```

- [ ] **Step 4: Build & run — verify pass**

Builder agent: `GemTests`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Gems/Gem.swift AuraCore/Tests/AuraCoreTests/GemTests.swift
git commit -m "feat(gems): cafe arrival radius 30→40 m — bike-forgiving product pass (ROH-59)"
```

---

## Task 6: App concretes — MapboxDetourRouting, CompassHeadingProvider, Mapbox free-drive reset

**Files:**
- Create: `Aura/Sources/Routing/MapboxDetourRouting.swift`
- Create: `Aura/Sources/Ride/CompassHeadingProvider.swift`
- Modify: `Aura/Sources/Routing/MapboxGuidanceSession.swift`

**Interfaces:**
- Produces: `struct MapboxDetourRouting: DetourRouting`; `final class CompassHeadingProvider: HeadingProviding`. Verification is build-only (thin SDK wrappers; behavior verified on device).

- [ ] **Step 1: MapboxDetourRouting**

Create `Aura/Sources/Routing/MapboxDetourRouting.swift`:

```swift
import AuraCore
import AuraKit

/// Single-leg cycling route to a gem, via the shipped `MapboxRoutingProvider`. A throw
/// (offline / no route) drives the controller's `headingOnly` fallback.
public struct MapboxDetourRouting: DetourRouting {
    public init() {}
    public func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route {
        let request = RouteRequest(origin: origin, destination: destination)
        let routes = try await MapboxRoutingProvider().routes(for: request)
        guard let best = routes.first else { throw DetourRoutingError.noRoute }
        return best
    }
}

enum DetourRoutingError: Error { case noRoute }
```

- [ ] **Step 2: CompassHeadingProvider**

Create `Aura/Sources/Ride/CompassHeadingProvider.swift`:

```swift
import AuraKit
import CoreLocation

/// Device compass heading (true north) as an AsyncStream. iOS-only; the offline detour
/// pointer consumes it. Not used on macOS (package CI never links this app file).
public final class CompassHeadingProvider: NSObject, HeadingProviding {
    public override init() { super.init() }

    public func headings() -> AsyncStream<Double> {
        #if os(iOS)
        return AsyncStream { continuation in
            let delegate = HeadingDelegate { continuation.yield($0) }
            let manager = CLLocationManager()
            manager.delegate = delegate
            manager.headingFilter = 3
            manager.startUpdatingHeading()
            continuation.onTermination = { _ in
                manager.stopUpdatingHeading()
                _ = delegate   // retain until termination
            }
        }
        #else
        return AsyncStream { $0.finish() }
        #endif
    }
}

#if os(iOS)
private final class HeadingDelegate: NSObject, CLLocationManagerDelegate {
    let onHeading: (Double) -> Void
    init(onHeading: @escaping (Double) -> Void) { self.onHeading = onHeading }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let deg = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        onHeading(deg)
    }
}
#endif
```

> Confirm the app target permits a `CLLocationManager` for heading without a new Info.plist key (the ride already uses location — heading needs no extra usage description beyond location When-In-Use). If the linter flags the strong `manager` capture, keep it — it must outlive the stream.

- [ ] **Step 3: Mapbox defensive free-drive reset (R1)**

In `MapboxGuidanceSession.swift`, in `start(route:)`, immediately before the `startActiveGuidance(with:startLegIndex:)` call, add:

```swift
        // Defensive reset (R1): a prior detour leg's teardown (startFreeDrive) is queued on the
        // next main-actor tick, so force a known state before starting active guidance again.
        nav.tripSession().startFreeDrive()
        nav.tripSession().startActiveGuidance(with: navRoutes, startLegIndex: 0)
```

- [ ] **Step 4: Build — verify it compiles (both platforms)**

Builder agent: build the app scheme (iOS sim) AND `swift build` the package on macOS host. Expected: both compile; no CoreLocation symbol leaks into the package.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Routing/MapboxDetourRouting.swift Aura/Sources/Ride/CompassHeadingProvider.swift Aura/Sources/Routing/MapboxGuidanceSession.swift
git commit -m "feat(gems): Mapbox detour routing + compass heading concretes + free-drive reset (ROH-59)"
```

---

## Task 7: GemDetailSheet "Take me there" CTA

**Files:**
- Modify: `Aura/Sources/Ride/GemDetailSheet.swift`

**Design skills:** consult `swiftui-patterns` / `swiftui-layout-components` and design judgment (native surface). Match the existing Plan-2 detail-sheet look; the CTA is the sheet's primary action.

**Interfaces:**
- Produces: `GemDetailSheet(gem:distanceText:onTakeMeThere:canRoute:)` where `onTakeMeThere: () -> Void` and `canRoute: Bool` (false ⇒ button disabled with a "waiting for GPS" hint, R6).

- [ ] **Step 1: Add the CTA + inputs**

In `GemDetailSheet.swift`, extend the inputs and add a button below the `why` block, above `.presentationDetents`:

```swift
    let gem: Gem
    let distanceText: String
    var canRoute: Bool = true
    var onTakeMeThere: () -> Void = {}
```

```swift
            Button {
                onTakeMeThere()
            } label: {
                Label("Take me there", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(AuraTheme.Font.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(AuraTheme.accent)
            .disabled(!canRoute)
            .accessibilityHint(canRoute ? "Starts a guided detour to this gem"
                                        : "Waiting for GPS")
            if !canRoute {
                Text("Waiting for GPS…")
                    .font(AuraTheme.Font.caption)
                    .foregroundStyle(AuraTheme.textSecondary)
            }
```

> Match the real `AuraTheme` token names by reading the theme file (e.g. `AuraTheme.Font.headline`, `AuraTheme.accent`, `AuraTheme.textSecondary` may differ — use the actual ones the file exports). Confirm the SF Symbol name via the SF Symbols availability approach noted in the roh44 memory if unsure; fall back to `"figure.outdoor.cycle"` or `"location.north.line.fill"` if the diamond glyph is unavailable on the deployment target.

- [ ] **Step 2: Build — verify it compiles**

Builder agent: build app scheme. Expected: compiles. (Wiring happens in Task 9; here the defaults keep it inert.)

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/GemDetailSheet.swift
git commit -m "feat(gems): Take me there CTA on GemDetailSheet (ROH-59)"
```

---

## Task 8: DetourOverlay + RideMapView detour polyline & dimmed track

**Files:**
- Create: `Aura/Sources/Ride/DetourOverlay.swift`
- Modify: `Aura/Sources/Ride/RideMapView.swift`

**Design skills:** consult `swiftui-layout-components`, `swiftui-animation` (arrow rotation / chip transitions honoring Reduce Motion), and design judgment. Mirror `NavigateHUDView`'s turn-card placement (top-center safe area, ~8 pt). Stop control is neutral, NOT pink.

**Interfaces:**
- Produces: `DetourOverlay(controller: GuidanceController, units: DistanceUnits, reduceMotion: Bool, onStop: () -> Void)` rendering: turn banner (`TurnCardView(state: controller.guidance?.turn ?? .starting)`) while guiding; compass arrow + straight-line distance + "Offline · approximate direction" while headingOnly; a destination chip (gem name · distance · **Stop** → `onStop`); and a transient "Arrived — <name>" chip driven by `controller.arrivalBanner`.
- `RideMapView` gains `var detourRoute: [Coordinate] = []` and dims the recorded track while `!detourRoute.isEmpty`.

- [ ] **Step 1: DetourOverlay**

Create `Aura/Sources/Ride/DetourOverlay.swift`:

```swift
import SwiftUI
import AuraCore
import AuraKit

/// The slim detour chrome over the free-ride HUD. Turn banner (guiding) or compass pointer
/// (offline), a destination chip with a NEUTRAL Stop (never confused with pink End Ride, R12),
/// and a transient arrival confirmation. Top-slotted to mirror NavigateHUDView's turn card (R13).
struct DetourOverlay: View {
    let controller: GuidanceController
    var units: DistanceUnits = .imperial
    var reduceMotion: Bool = false
    var onStop: () -> Void

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            if let arrived = controller.arrivalBanner {
                arrivalChip(arrived)
            } else if let gem = controller.destinationGem {
                switch controller.phase {
                case .guiding:
                    if let vm = controller.guidance {
                        TurnCardView(state: vm.turn, reduceMotion: reduceMotion)
                    }
                    destinationChip(gem, distance: vm_distance())
                case .headingOnly:
                    headingPointer(gem)
                    destinationChip(gem, distance: arrowDistanceText())
                case .routing:
                    routingChip(gem)
                case .inactive:
                    EmptyView()
                }
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .animation(reduceMotion ? nil : .snappy, value: controller.phase)
    }

    private func destinationChip(_ gem: Gem, distance: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.fill").foregroundStyle(AuraTheme.accent)
            Text(gem.name).font(AuraTheme.Font.subheadline).lineLimit(1)
            Text(distance).font(AuraTheme.Font.caption).foregroundStyle(AuraTheme.textSecondary)
            Spacer(minLength: 8)
            Button("Stop", action: onStop)
                .font(AuraTheme.Font.subheadline)
                .buttonStyle(.bordered)                 // neutral — NOT .destructive
                .accessibilityLabel("Stop detour")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func headingPointer(_ gem: Gem) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 34))
                .foregroundStyle(AuraTheme.accent)
                .rotationEffect(.degrees(controller.headingArrow?.relativeBearingDegrees ?? 0))
                .animation(reduceMotion ? nil : .easeInOut, value: controller.headingArrow?.relativeBearingDegrees)
            Text("Offline · approximate direction")
                .font(AuraTheme.Font.caption2).foregroundStyle(AuraTheme.textSecondary)
        }
        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func routingChip(_ gem: Gem) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Routing to \(gem.name)…").font(AuraTheme.Font.subheadline)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func arrivalChip(_ gem: Gem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AuraTheme.accent)
            Text("Arrived — \(gem.name)").font(AuraTheme.Font.subheadline)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(reduceMotion ? .identity : .opacity)
    }

    private func vm_distance() -> String {
        // distance-remaining from the guidance update, formatted; fall back to blank.
        guard let meters = controller.guidance?.lastUpdate?.distanceRemainingMeters else { return "" }
        return RideStatsFormatter.maneuverDistance(meters: meters, units: units)
    }
    private func arrowDistanceText() -> String {
        guard let m = controller.headingArrow?.straightLineDistanceMeters else { return "" }
        return RideStatsFormatter.maneuverDistance(meters: m, units: units)
    }
}
```

> Fix token/formatter names against the codebase: `AuraTheme.Font.*`, `AuraTheme.Spacing.sm`, `AuraTheme.accent`, `AuraTheme.textSecondary`, and `RideStatsFormatter.maneuverDistance(meters:units:)` (used the same way in `RideHUDView` per the Plan-2 memory). `TurnCardView` and `GuidanceUpdate.distanceRemainingMeters` are shipped. Resolve the `vm` reference in the `.guiding` case (bind `if let vm = controller.guidance` before using `vm_distance`); simplify if the compiler complains.

- [ ] **Step 2: RideMapView detour polyline + dim track**

In `RideMapView.swift`, add the input and a `@MapContentBuilder`:

```swift
    var detourRoute: [Coordinate] = []
```

Add to the map content (after `routeRibbon`):

```swift
    @MapContentBuilder
    private var detourPolyline: some MapContent {
        if detourRoute.count > 1 {
            PolylineAnnotationGroup {
                PolylineAnnotation(lineCoordinates: detourRoute.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .lineColor(StyleColor(AuraTheme.routeUIColor))
                .lineWidth(6)
            }
        }
    }
```

And dim the recorded track when a detour is drawn: where `routeRibbon` sets the track `lineColor`, when `!detourRoute.isEmpty` use the dimmed variant already used for the "behind" segment (e.g. `UIColor(AuraTheme.routeLine.opacity(0.25))`). Add `detourPolyline` into the `Map { … }` body after `routeRibbon`.

> Match the real Mapbox v11 `@MapContentBuilder` API already used in this file (`PolylineAnnotationGroup`/`PolylineAnnotation`/`StyleColor`), per the group-rides memory note about MapboxMaps v11.

- [ ] **Step 3: Build — verify it compiles**

Builder agent: build app scheme. Expected: compiles.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/DetourOverlay.swift Aura/Sources/Ride/RideMapView.swift
git commit -m "feat(gems): slim detour overlay + detour polyline/dimmed track (ROH-59)"
```

---

## Task 9: RideHUDView wiring (build controller, inject, thread CTA, host overlay, arbiter)

**Files:**
- Modify: `Aura/Sources/Ride/RideHUDView.swift`

**Interfaces:**
- Consumes: everything above. Builds a `GuidanceController` from app concretes, injects it into the coordinator, wires the store arbiter, threads the CTA, hosts `DetourOverlay`, passes `detourRoute`.

- [ ] **Step 1: Build the controller & inject at coordinator construction**

`RideSessionCoordinator` is created inline as `@State`. Change the initializer to build and pass a `GuidanceController`:

```swift
    @State private var coordinator: RideSessionCoordinator
    @State private var guidance: GuidanceController

    init() {
        let controller = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: MapboxGuidanceSession()) },
            routing: MapboxDetourRouting(),
            heading: CompassHeadingProvider())
        _guidance = State(initialValue: controller)
        _coordinator = State(initialValue: RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
            workout: WorkoutWriter.shared, guidance: controller))
    }
```

> If `RideHUDView` currently has no explicit `init` (it used inline `@State` defaults), converting to an explicit `init` requires moving any other `@State` defaults into it. Keep every existing `@State` default; only add the two above. `units`/`turnHaptics` on the controller default acceptably; set `guidance.units`/`turnHaptics` from `settings` inside the existing `.task` if the settings env is needed (mirror how NavigateHUD sets `guidance.units`).

- [ ] **Step 2: Wire the arbiter, CTA, overlay, and map**

In the `.task` that builds the store, set the arbiter predicate:

```swift
        store.detourActive = { [coordinator] in coordinator.isDetouring }
```

Thread the CTA in the detail sheet:

```swift
        .sheet(item: Binding(get: { gems?.selectedGem },
                             set: { gems?.selectedGem = $0 })) { gem in
            GemDetailSheet(
                gem: gem,
                distanceText: gemDistanceText(gem),
                canRoute: gems?.riderCoordinate != nil,
                onTakeMeThere: {
                    guard let origin = gems?.riderCoordinate else { return }
                    gems?.selectedGem = nil                    // dismiss the sheet
                    guidance.requestDetour(gem, from: origin)  // R6
                })
        }
```

Host the overlay (top) and feed the map:

```swift
        .overlay(alignment: .top) {
            if guidance.isDetouring || guidance.arrivalBanner != nil {
                DetourOverlay(controller: guidance, units: settings.units,
                              reduceMotion: reduceMotion, onStop: { guidance.cancel() })
                    .padding(.top, 8)
            }
        }
```

```swift
        RideMapView(track: coordinator.track,
                    gems: gems?.visiblePins ?? [],
                    seenGemIDs: gems?.seenIDs ?? [],
                    onSelectGem: { gem in gems?.select(gem) },
                    detourRoute: guidance.activeRoute?.geometry ?? [],
                    viewport: $viewport)
```

> `reduceMotion` — add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` if not already present. The existing peek-card `.overlay(alignment: .top)` remains; because the store arbiter suppresses `activeCard` during a detour, the two top overlays won't both show. Verify z-order: the DetourOverlay overlay is declared AFTER the peek-card overlay so it wins if both ever coexist.

- [ ] **Step 3: Build — verify it compiles & the app runs**

Builder agent: build + install the app on the iOS simulator; launch. Expected: builds, launches, Explore HUD renders (no detour until a gem CTA is tapped). This is the first end-to-end wiring — confirm no crash on launch and that tapping a gem → detail sheet shows the "Take me there" button.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/RideHUDView.swift
git commit -m "feat(gems): wire detour — controller, arbiter, CTA, overlay, map route (ROH-59)"
```

---

## Task 10: Full-suite regression + package build gate

**Files:** none (verification task).

- [ ] **Step 1: Run the whole package test suite**

Builder agent: run ALL `AuraCore` + `AuraKit` tests (the ~381-test suite from Plan 2 plus the ~20 new). Expected: all green. Investigate any regression before proceeding.

- [ ] **Step 2: Build the app for the simulator + `swift build` on macOS host**

Builder agent: confirm both the iOS app scheme and the macOS package build clean (SwiftLint 0.64.1 pinned; Swift 6 strict concurrency across all targets). Expected: no warnings/errors, no CoreLocation leak into the package.

- [ ] **Step 3: Commit any lint fixes**

```bash
git add -A && git commit -m "chore(gems): lint + regression green for Plan 3 detour (ROH-59)"
```

(If nothing to fix, skip.)

---

## Self-review checklist (run before handing off to execution)

- **Spec coverage:** DetourMachine (T1) · GuidanceController routing/guiding (T2a) · offline heading + recovery (T2b) · arbiter (T3) · coordinator inject/forward/detach (T4) · arrival radii (T5) · Mapbox/compass concretes + R1 reset (T6) · CTA (T7) · overlay + map route (T8) · wiring (T9) · regression gate (T10). R1–R16 all land in a task. ✅
- **No schema change:** confirmed — no V5, nothing persisted. ✅
- **Stop ≠ End Ride:** T8 neutral `.bordered` Stop, top-slotted, "Stop detour" a11y label. ✅
- **Type consistency:** `GuidanceControlling` (T2a) matches coordinator use (T4); `detourActive` (T3) matches wiring (T9); `requestDetour(_:from:)`/`cancel()`/`activeRoute`/`arrivalBanner`/`isDetouring` names consistent T2a→T9. ✅
- **Placeholder scan:** every code step carries real code; "confirm signature X" notes point implementers at the file to read, not TODO stubs. ✅
- **Device-verify (post-merge, sim can't drive GPS):** live turn-by-turn detour, arrival→detach with ride still recording + stats intact, offline heading arrow + affordance, T3-haptic/card suppression, two-location-consumer safety (R16) — via the route-playback recipe.
