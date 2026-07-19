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
    /// Set when the most recent `startRiding()` call failed server-side; cleared at the
    /// start of the next attempt. The lobby view surfaces this as a retry affordance.
    public private(set) var startFailed = false
    /// Set when the most recent `end()` call failed server-side (Task 8 wires retry).
    public private(set) var endFailed = false

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
    /// The event-consumption loop this session OWNS once live (so its own `ingest` — names/
    /// toasts/host-end dissolve — runs on the live stream). Torn down alongside the ticker.
    private var eventLoopTask: Task<Void, Never>?
    /// Idempotency latch for `beginLiveSession()`: the lobby `.task` and the `.riding`
    /// `.task` both call it, and it must subscribe exactly once. Reset on teardown.
    private var didBeginLive = false
    private var isRefreshingRoster = false
    public private(set) var hostID: UUID?

    /// Projects the observable `Phase` onto the three phases reconciliation reasons about;
    /// `nil` for the non-live phases (`.idle`, `.createFailed`, etc.) that don't participate.
    private var lifecyclePhase: RideLifecyclePhase? {
        switch phase {
        case .lobby: return .lobby
        case .riding: return .riding
        case .ended: return .ended
        default: return nil
        }
    }

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
        let status = RideLifecycleStatus(hostID: joined.ride.hostID,
                                         startedAt: joined.ride.startedAt, endedAt: joined.ride.endedAt)
        switch authoritativePhase(status, current: .lobby) {
        case .riding: phase = .riding
        default:      phase = .lobby
        }
    }

    /// Host-only: asks the backend to mark the ride started (stamps `started_at` durably),
    /// then advances to `.riding` only once the server confirms. On failure sets
    /// `startFailed` and stays in `.lobby` — the lobby view's Retry re-invokes this.
    public func startRiding() async {
        guard let rideID else { return }
        startFailed = false
        do {
            try await backend.startRide(rideID: rideID)
            phase = .riding
        } catch {
            startFailed = true
        }
    }

    /// Called by the production call sites (the lobby `.task` and the `.riding` `.task`)
    /// once a session exists: subscribes to the live transport and OWNS the event loop so
    /// this session's `ingest` (names/toasts/host-end dissolve) runs on the live stream —
    /// `RideSession.start(roster:)` would instead spawn its own loop driving only
    /// `RideSession.ingest` (dots), so the group layer would never see names/toasts live.
    /// Idempotent (the lobby and the riding view both call it); tests may still drive
    /// `tick`/`ingest` directly for the deterministic seams.
    public func beginLiveSession() async {
        guard !didBeginLive, let session = rideSession else { return }
        didBeginLive = true

        // Populate nameMap AND capture the roster so joined-but-not-yet-moving members
        // seed presence (they show in the lobby/roster before their first position).
        let members = await refreshRoster()
        let seedPeers = members.map {
            RidePeer(userID: $0.userID, displayName: $0.displayName, status: .awaiting)
        }

        let events = session.startManaged(roster: seedPeers)
        eventLoopTask = Task { [weak self] in
            for await event in events {
                await self?.ingest(event)
            }
        }
        startTicker()
        peers = session.peers
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
            teardownLive(session)
        case .memberLeft(let id):
            toasts.append(.left(nameMap[id] ?? "Rider"))
        default:
            break
        }
        await session.ingest(event)
        peers = session.peers
        isLive = session.isLive
    }

    /// Merges the backend roster's display names into `nameMap` and returns the fetched
    /// members (so `beginLiveSession` can seed presence with everyone who has joined).
    /// Guarded by an in-flight flag so a burst of unknown-peer positions collapses into a
    /// single fetch; a coalesced call returns `[]` (its caller only needs the name merge,
    /// which the in-flight fetch is already doing).
    @discardableResult
    private func refreshRoster() async -> [RosterMember] {
        guard !isRefreshingRoster else { return [] }
        isRefreshingRoster = true
        defer { isRefreshingRoster = false }
        guard let rideID, let members = try? await backend.roster(rideID: rideID) else { return [] }
        for member in members {
            nameMap[member.userID] = member.displayName
        }
        return members
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
        teardownLive(rideSession)
    }

    public func leave() async {
        if let rideID { try? await backend.leaveRide(rideID: rideID) }
        phase = .ended
        teardownLive(rideSession)
    }

    /// Single teardown path for every dissolve (host end, member leave, host-end wire
    /// signal): stops the inner session's subscription, cancels the owned event loop and
    /// ticker, and clears `didBeginLive` so a fresh session could begin again.
    private func teardownLive(_ session: RideSession?) {
        session?.stop()
        eventLoopTask?.cancel()
        eventLoopTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        didBeginLive = false
    }
}
