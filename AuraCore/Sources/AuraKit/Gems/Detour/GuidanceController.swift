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
    /// Test-observable handle on the in-flight route fetch (fetchRoute/probeNetworkRecovery).
    /// Not read by production code — lets tests await real completion instead of a fixed sleep.
    @ObservationIgnored private(set) var pendingRoutingTask: Task<Void, Never>?

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
        pendingRoutingTask = Task { [weak self] in
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
        pendingRoutingTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.routing.route(from: origin, to: gem.coordinate)) != nil else { return }
            guard gen == self.requestGeneration,
                  case .headingOnly(let current) = self.phase, current.id == gem.id else { return }
            self.feedInternal(.networkRecovered, origin: origin)
        }
    }
}
