import Foundation
import AuraCore

/// A membership-related notification the UI drains from `GroupRideSession.toasts`.
public enum GroupToastEvent: Equatable, Sendable {
    case joined(String)
    case left(String)
    case hostEnded
}

/// The group-ride session owner: create/join lifecycle, phase, the live tick layer,
/// and membership toasts (nameMap resolution + joined/left/hostEnded notifications).
@MainActor
@Observable
public final class GroupRideSession {
    public enum Phase: Equatable, Sendable {
        case idle, lobby, riding, ended, routeUnavailable, createFailed, needsDisplayName, joinFailed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var isHost: Bool = false
    public private(set) var rideID: UUID?
    public private(set) var joinCode: JoinCode?
    public private(set) var route: Route?
    public private(set) var peers: [RidePeer] = []
    public private(set) var isLive: Bool = false
    /// userID -> display name, populated from `backend.roster(rideID:)`.
    public private(set) var nameMap: [UUID: String] = [:]
    /// Append-only membership notifications; the UI drains this.
    public private(set) var toasts: [GroupToastEvent] = []

    private let backend: any GroupRideBackend
    private let transport: any RideSessionTransport
    private let displayNameProvider: @Sendable () -> String
    private let cadence: LiveShareCadence
    private var rideSession: RideSession?
    private var currentLifecycle: RideLifecycle = .foreground
    private var tickerTask: Task<Void, Never>?
    private var isRefreshingRoster = false

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
            let selfUserID = try await backend.currentUserID()
            let routeData = try JSONEncoder().encode(inputRoute)
            let ride = try await backend.createRide(route: routeData)
            rideID = ride.id
            joinCode = ride.joinCode
            route = inputRoute
            isHost = (ride.hostID == selfUserID)
            rideSession = RideSession(rideID: ride.id, selfUserID: selfUserID,
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
        let selfUserID: UUID
        let joined: JoinedRide
        do {
            selfUserID = try await backend.currentUserID()
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
        isHost = (joined.ride.hostID == selfUserID)
        rideSession = RideSession(rideID: joined.ride.id, selfUserID: selfUserID,
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
    /// already-known peer is deliberately silent (D11). `.memberLeft` always toasts `.left`.
    public func ingest(_ event: TransportEvent) async {
        guard let session = rideSession else { return }
        switch event {
        case .position(let payload) where nameMap[payload.userID] == nil:
            await refreshRoster()
            if let name = nameMap[payload.userID] {
                toasts.append(.joined(name))
            }
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
