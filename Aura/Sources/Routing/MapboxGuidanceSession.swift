import Combine
import CoreLocation
import OSLog
import MapboxDirections
import MapboxNavigationCore
import AuraCore

/// `AuraCore.GuidanceSession` backed by the Mapbox Navigation v3 active-guidance
/// stack. Bridges Mapbox's `routeProgress` / `waypointsArrival` / `voiceInstructions`
/// Combine publishers into a single `AsyncStream<GuidanceEvent>`, so the navigate HUD
/// (and `GuidanceViewModel`) never import the Mapbox SDK.
///
/// All Mapbox-specific decisions — resolving the exact `NavigationRoutes` the rider
/// selected, decoding `RouteProgress` into a plain distance + instruction, detecting
/// final-destination arrival — live here, behind the pure protocol.
@MainActor
public final class MapboxGuidanceSession: GuidanceSession {

    private static let log = Logger(subsystem: "app.aura", category: "guidance")

    private var cancellables = Set<AnyCancellable>()
    private var continuation: AsyncStream<GuidanceEvent>.Continuation?
    /// Bumped on every `start()`. Captured by each stream's termination handler so a
    /// superseded session's async teardown can't free-drive over a newer one.
    private var generation = 0

    public init() {}

    // Mapbox v3 setup is one linear configuration block; splitting hides the sequence.
    // swiftlint:disable:next function_body_length
    public func start(route: AuraCore.Route) async -> AsyncStream<GuidanceEvent> {
        // Defensive: end any prior stream (so a stale consumer can't hang) and drop
        // its subscriptions before standing up a new session.
        continuation?.finish()
        cancellables.removeAll()
        generation &+= 1
        let generation = self.generation

        let (stream, continuation) = AsyncStream<GuidanceEvent>.makeStream()
        self.continuation = continuation

        guard let navRoutes = await resolveRoutes(for: route) else {
            // Couldn't establish a route — finish immediately; the VM degrades the
            // turn card to its "unavailable" prompt while recording + map still work.
            continuation.finish()
            return stream
        }

        let nav = AuraNavigation.provider.mapboxNavigation

        // Start active turn-by-turn guidance.
        nav.tripSession().startActiveGuidance(with: navRoutes, startLegIndex: 0)

        // Self-healing teardown: whether the stream ends via `stop()` or the consumer
        // simply stops iterating (e.g. its task is cancelled), return the SDK to
        // free-drive and drop subscriptions — but only if this is still the active
        // generation, so a re-`start()` isn't clobbered by the old stream's cleanup.
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.teardown(generation: generation) }
        }

        // Tracks the active route id so we can detect a reroute swap in routeProgress.
        // Declared as a local var here so it resets to nil every time start() is called.
        var lastRouteId: RouteId?

        // Route progress → turn-card updates + rerouted geometry swap.
        nav.navigation().routeProgress
            .receive(on: DispatchQueue.main)
            .sink { state in
                guard let progress = state?.routeProgress else { return }
                continuation.yield(.progress(Self.guidanceUpdate(from: progress)))
                // Emit the new polyline shape when the active route changes (post-reroute).
                // Skip the very first routeId assignment (that's the initial route, not a swap).
                if lastRouteId != progress.routeId {
                    let isFirst = (lastRouteId == nil)
                    lastRouteId = progress.routeId
                    if !isFirst, let coords = progress.route.shape?.coordinates {
                        continuation.yield(.rerouted(coords.map {
                            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
                        }))
                    }
                }
            }
            .store(in: &cancellables)

        // Rerouting started → show the recalculating cue in the HUD.
        nav.navigation().rerouting
            .receive(on: DispatchQueue.main)
            .sink { status in
                if status.event is ReroutingStatus.Events.FetchingRoute {
                    continuation.yield(.rerouting)
                }
            }
            .store(in: &cancellables)

        // Arrival at the final destination → end the ride.
        nav.navigation().waypointsArrival
            .receive(on: DispatchQueue.main)
            .sink { status in
                if status.event is WaypointArrivalStatus.Events.ToFinalDestination {
                    continuation.yield(.arrivedAtDestination)
                }
            }
            .store(in: &cancellables)

        // Voice instructions → spoken prompts (the VM/view gate on mute + settings).
        nav.navigation().voiceInstructions
            .receive(on: DispatchQueue.main)
            .sink { state in
                continuation.yield(.spokenInstruction(state.spokenInstruction.text))
            }
            .store(in: &cancellables)

        return stream
    }

    public func stop() {
        // Finish the stream; the termination handler does the actual teardown on the
        // next main-actor tick (so stop() and consumer-cancellation share one path).
        continuation?.finish()
        continuation = nil
    }

    /// Drops subscriptions and returns the SDK to free-drive — but only if this stream
    /// is still the active generation (a re-`start()` supersedes it).
    private func teardown(generation: Int) {
        guard generation == self.generation else { return }
        cancellables.removeAll()
        // Return to free-drive so the SDK session stays warm for the next ride.
        AuraNavigation.provider.mapboxNavigation.tripSession().startFreeDrive()
    }

    // MARK: - Route resolution

    /// Prefers the routes already fetched in preview (via `NavigationRouteRegistry`) so
    /// we navigate the EXACT alternative the rider selected (Flattest / Most paths / …)
    /// instead of Mapbox's default main route. Falls back to a re-fetch on a registry
    /// miss (e.g. relaunch mid-flow), returning nil if even that fails.
    private func resolveRoutes(for route: AuraCore.Route) async -> NavigationRoutes? {
        if let entry = NavigationRouteRegistry.shared.entry(for: route.id) {
            if entry.mbRouteIndex == 0 {
                return entry.routes
            }
            return await entry.routes.selectingAlternativeRoute(at: entry.mbRouteIndex - 1) ?? entry.routes
        }

        let originCoord = CLLocationCoordinate2D(latitude: route.origin.latitude,
                                                 longitude: route.origin.longitude)
        let destCoord = CLLocationCoordinate2D(latitude: route.destination.latitude,
                                               longitude: route.destination.longitude)
        let options = NavigationRouteOptions(
            waypoints: [
                MapboxDirections.Waypoint(coordinate: originCoord),
                MapboxDirections.Waypoint(coordinate: destCoord)
            ],
            profileIdentifier: .cycling
        )
        options.includesAlternativeRoutes = false
        do {
            return try await AuraNavigation.provider.mapboxNavigation
                .routingProvider()
                .calculateRoutes(options: options)
                .value
        } catch {
            // Degrade to the "unavailable" turn card, but leave a breadcrumb — this is
            // the only signal that guidance (not just the registry lookup) failed.
            Self.log.error("Guidance route fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Progress decoding

    /// Decodes a `GuidanceUpdate` from Mapbox `RouteProgress`. The maneuver distance and
    /// instruction come from the current/upcoming step (what you're approaching); the
    /// three cruising fields (distance-remaining, duration-remaining, current street) come
    /// from whole-route progress.
    private static func guidanceUpdate(from progress: RouteProgress) -> GuidanceUpdate {
        let leg = progress.currentLegProgress
        let distanceToManeuver = leg.currentStepProgress.distanceRemaining
        let upcoming = leg.upcomingStep
        // `remainingSteps.first` IS the upcoming step (steps.suffix(from: stepIndex + 1)),
        // so the maneuver *after* the upcoming one — the "then …" preview — is the next element.
        let afterUpcoming = leg.remainingSteps.dropFirst().first
        let instruction = upcoming?.instructions ?? leg.currentStep.instructions
        return GuidanceUpdate(
            distanceToManeuverMeters: distanceToManeuver,
            instruction: instruction,
            distanceRemainingMeters: progress.distanceRemaining,
            durationRemainingSeconds: progress.durationRemaining,
            currentStreetName: leg.currentStep.names?.first,
            maneuver: mapManeuver(upcoming),
            // The then-chip only renders when this label is non-empty (TurnCardPresenter
            // returns nil otherwise), so give it the next street name, then the instruction.
            nextManeuver: mapManeuver(afterUpcoming,
                                      label: afterUpcoming?.names?.first ?? afterUpcoming?.instructions)
        )
    }

    /// Maps a Mapbox `RouteStep` to the engine-independent `AuraCore.Maneuver`. A `default`
    /// on each switch degrades unknown/new SDK cases to `.other` / `.none` (a generic arrow)
    /// rather than failing the build — acceptable, not a blocker. Note Mapbox has no
    /// `makeUTurn` maneuver *type*: a U-turn is a `.turn`/etc. with `maneuverDirection == .uTurn`,
    /// which flows through the modifier below and picks the U-turn glyph.
    private static func mapManeuver(_ step: RouteStep?, label: String? = nil) -> Maneuver? {
        guard let step else { return nil }
        let kind: Maneuver.Kind
        switch step.maneuverType {
        case .turn: kind = .turn
        case .reachFork: kind = .fork
        case .takeRoundabout, .turnAtRoundabout, .exitRoundabout: kind = .roundabout
        case .takeRotary, .exitRotary: kind = .rotary
        case .merge: kind = .merge
        case .takeOnRamp: kind = .onRamp
        case .takeOffRamp: kind = .offRamp
        case .depart: kind = .depart
        case .arrive: kind = .arrive
        case .`continue`, .passNameChange: kind = .continueOn
        case .reachEnd: kind = .endOfRoad
        default: kind = .other // useLane, heedWarning, and any future case
        }
        let modifier: Maneuver.Modifier
        switch step.maneuverDirection {
        case .left: modifier = .left
        case .right: modifier = .right
        case .slightLeft: modifier = .slightLeft
        case .slightRight: modifier = .slightRight
        case .sharpLeft: modifier = .sharpLeft
        case .sharpRight: modifier = .sharpRight
        case .straightAhead: modifier = .straight
        case .uTurn: modifier = .uTurn
        default: modifier = .none // .undefined or nil
        }
        return Maneuver(kind: kind, modifier: modifier, label: label)
    }
}
