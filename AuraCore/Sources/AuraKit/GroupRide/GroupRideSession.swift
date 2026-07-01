import Foundation
import AuraCore

/// A membership-related notification the UI drains from `GroupRideSession.toasts`.
public enum GroupToastEvent: Equatable, Sendable {
    case joined(String)
    case left(String)
    case hostEnded
}

/// The group-ride session owner: create/join lifecycle, phase, the live tick layer,
/// and membership toasts (nameMap resolution + joined/left notifications). On a
/// member's session, a `.memberLeft` whose id matches the ride's host is recognized
/// as the host ending the ride (D9/D12: the host has no graceful-leave action, so
/// this is the wire's only signal) — it toasts `.hostEnded` and dissolves the live layer.
@MainActor
@Observable
public final class GroupRideSession {
    public enum Phase: Equatable, Sendable {
        case idle, lobby, riding, ended, routeUnavailable, createFailed, needsDisplayName, joinFailed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var isHost: Bool = false
    public private(set) var rideID: UUID?
    public private(set) var selfUserID: UUID?
    public private(set) var joinCode: JoinCode?
    public private(set) var route: Route?
    public private(set) var peers: [RidePeer] = []
    public private(set) var isLive: Bool = false
    /// userID -> display name, populated from `backend.roster(rideID:)`.
    public private(set) var nameMap: [UUID: String] = [:]
    /// Append-only membership notifications; the UI drains this.
    public private(set) var toasts: [GroupToastEvent] = []

    /// The seam the ride's `RideSessionCoordinator` publishes the rider's own position
    /// through, so peers see this rider's dot on the map. `rideSession` (the private inner
    /// live session) conforms to `GroupLocationSink`; this simply exposes it read-only for
    /// the production call site (`NavigateHUDView`) to hand to `coordinator.start(groupSink:)`.
    public var locationSink: (any GroupLocationSink)? { rideSession }

    private let backend: any GroupRideBackend
    private let transport: any RideSessionTransport
    private let displayNameProvider: @Sendable () -> String
    private let cadence: LiveShareCadence
    private var rideSession: RideSession?
    private var currentLifecycle: RideLifecycle = .foreground
    private var tickerTask: Task<Void, Never>?
    private var isRefreshingRoster = false
    private var hostID: UUID?

    public init(backend: any GroupRideBackend, transport: any RideSessionTransport,
                displayNameProvider: @escaping @Sendable () -> String, cadence: LiveShareCadence = .init()) {
        self.backend = backend
        self.transport = transport
        self.displayNameProvider = displayNameProvider
        self.cadence = cadence
    }

    public func create(route inputRoute: Route) async {
        guard DisplayName.normalized(displayNameProvider()) != nil else {
            phase = .needsDisplayName
            return
        }
        do {
            let resolvedSelfUserID = try await backend.currentUserID()
            let routeData = try JSONEncoder().encode(inputRoute)
            let ride = try await backend.createRide(route: routeData)
            rideID = ride.id
            joinCode = ride.joinCode
            route = inputRoute
            hostID = ride.hostID
            selfUserID = resolvedSelfUserID
            isHost = (ride.hostID == resolvedSelfUserID)
            rideSession = RideSession(rideID: ride.id, selfUserID: resolvedSelfUserID,
                                      transport: transport, cadence: cadence)
            phase = .lobby
        } catch {
            phase = .createFailed
        }
    }

    public func join(code: JoinCode) async {
        guard DisplayName.normalized(displayNameProvider()) != nil else {
            phase = .needsDisplayName
            return
        }
        let resolvedSelfUserID: UUID
        let joined: JoinedRide
        do {
            resolvedSelfUserID = try await backend.currentUserID()
            joined = try await backend.joinRide(code: code)
        } catch {
            phase = .joinFailed
            return
        }
        guard let decodedRoute = try? JSONDecoder().decode(Route.self, from: joined.route) else {
            phase = .routeUnavailable
            try? await backend.leaveRide(rideID: joined.ride.id)
            return
        }
        rideID = joined.ride.id
        joinCode = joined.ride.joinCode
        route = decodedRoute
        hostID = joined.ride.hostID
        selfUserID = resolvedSelfUserID
        isHost = (joined.ride.hostID == resolvedSelfUserID)
        rideSession = RideSession(rideID: joined.ride.id, selfUserID: resolvedSelfUserID,
                                  transport: transport, cadence: cadence)
        phase = .riding
    }

    public func startRiding() {
        phase = .riding
    }

    /// Called by the production call site once it has entered `.riding` (after `create`
    /// + `startRiding()` or `join`): starts the inner live session + the wall-clock
    /// ticker. Tests never call this — they drive `tick`/`ingest` directly.
    public func beginLiveSession(roster: [RidePeer] = []) async {
        guard let session = rideSession else { return }
        await session.start(roster: roster)
        startTicker()
    }

    /// The sole time entry point. Publishes buffered own-points when due, ages silent
    /// peers, then snapshots the inner session's state into the observable stored props
    /// so SwiftUI repaints promptly rather than waiting for the next tick.
    public func tick(now: Date) async {
        guard let session = rideSession else { return }
        await session.publishIfDue(now: now, lifecycle: currentLifecycle)
        session.stalenessTick(now: now)
        peers = session.peers
        isLive = session.isLive
    }

    /// Resolves membership toasts for a transport event, forwards it to the inner session,
    /// then snapshots peers/isLive. A `.position` from an unknown peer triggers a throttled
    /// roster refresh and (if a name resolves) a `.joined` toast; a motion-state change on an
    /// already-known peer is deliberately silent (D11). `.memberLeft` toasts `.left` for a
    /// normal member — but when the departing id is the ride's host (D9/D12: the host has no
    /// graceful-leave action, so this is the only signal that the host ended the ride), it
    /// instead toasts `.hostEnded`, moves to `.ended`, and tears down the live layer.
    public func ingest(_ event: TransportEvent) async {
        guard let session = rideSession else { return }
        switch event {
        case .position(let payload) where nameMap[payload.userID] == nil:
            await refreshRoster()
            if let name = nameMap[payload.userID] {
                toasts.append(.joined(name))
            }
        case .memberLeft(let id) where id == hostID:
            toasts.append(.hostEnded)
            phase = .ended
            session.stop()
            tickerTask?.cancel()
            tickerTask = nil
        case .memberLeft(let id):
            toasts.append(.left(nameMap[id] ?? "Rider"))
        default:
            break
        }
        await session.ingest(event)
        peers = session.peers
        isLive = session.isLive
    }

    /// Merges the backend roster's display names into `nameMap`. Guarded by an in-flight
    /// flag so a burst of unknown-peer positions collapses into a single fetch.
    private func refreshRoster() async {
        guard !isRefreshingRoster else { return }
        isRefreshingRoster = true
        defer { isRefreshingRoster = false }
        guard let rideID, let members = try? await backend.roster(rideID: rideID) else { return }
        for member in members {
            nameMap[member.userID] = member.displayName
        }
    }

    /// Production-only: drives `tick(now:)` off a real wall clock. Tests never call this —
    /// they drive `tick`/`ingest` directly with injected times.
    func startTicker() {
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(now: Date())
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func end() async {
        if let rideID { try? await backend.endRide(rideID: rideID) }
        phase = .ended
        rideSession?.stop()
        tickerTask?.cancel()
        tickerTask = nil
    }

    public func leave() async {
        if let rideID { try? await backend.leaveRide(rideID: rideID) }
        phase = .ended
        rideSession?.stop()
        tickerTask?.cancel()
        tickerTask = nil
    }
}
