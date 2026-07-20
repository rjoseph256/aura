import Foundation
import AuraCore

/// A membership-related notification the UI drains from `GroupRideSession.toasts`.
public enum GroupToastEvent: Equatable, Sendable {
    case joined(String)
    case left(String)
    case hostEnded
}

/// The group-ride session owner: create/join lifecycle, phase, the live tick layer,
/// and membership toasts (nameMap resolution + joined/left notifications). A
/// `.rideEnded` broadcast (or an authoritative `.connected` reconcile that reads
/// `endedAt`) is how a member's session learns the ride ended — it toasts
/// `.hostEnded` for a guest and dissolves the live layer.
@MainActor
@Observable
public final class GroupRideSession {
    public enum Phase: Equatable, Sendable {
        case idle, lobby, riding, ended, routeUnavailable, createFailed, needsDisplayName, joinFailed
    }

    /// Which end/leave the caller intends — drives whether the rider waits on it (and sees
    /// pending/timeout feedback) or it's fire-and-forget (keep-riding leave).
    public enum FinishIntent: Sendable, Equatable { case hostEnd, memberEnd, memberLeave }

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
    /// Set when the most recent `end()`/`leave()` call failed server-side. The HUD surfaces
    /// this as a retry affordance; `retryEndIfNeeded()` re-attempts without faking success.
    public private(set) var endFailed = false
    /// True from a waited-on end/leave tap (hostEnd/memberEnd) until it resolves. Drives the
    /// "Ending…" pill and disables the End control. Never set for a keep-riding leave.
    public private(set) var isEnding = false

    /// The seam the ride's `RideSessionCoordinator` publishes the rider's own position
    /// through, so peers see this rider's dot on the map. `rideSession` (the private inner
    /// live session) conforms to `GroupLocationSink`; this simply exposes it read-only for
    /// the production call site (`NavigateHUDView`) to hand to `coordinator.start(groupSink:)`.
    public var locationSink: (any GroupLocationSink)? { rideSession }

    private let backend: any GroupRideBackend
    private let transport: any RideSessionTransport
    private let displayNameProvider: @Sendable () -> String
    private let cadence: LiveShareCadence
    /// How long a waited-on end/leave may hang before it's treated as a transient failure
    /// (surfaces `endFailed`). Injected (defaulted) so tests drive the timeout deterministically.
    private let endTimeout: Duration
    /// The timeout clock — injected so tests race the backend call against a controllable sleep
    /// instead of a real one.
    private let sleep: @Sendable (Duration) async throws -> Void
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
    /// A `startRiding()` the server hasn't confirmed yet — gates `retryStartIfNeeded()`.
    private var pendingStart = false
    /// An `end()`/`leave()` the server hasn't confirmed yet — gates `retryEndIfNeeded()`.
    private var pendingEnd = false
    /// The intent of the in-flight/last end/leave, so `retryEndIfNeeded()` replays the same one.
    private var finishIntent: FinishIntent = .hostEnd
    // TODO(backoff timer): production auto-retry. Spec calls for a session-held backoff
    // Task (2s, 4s, 8s, cap 8s) started when startFailed/endFailed first sets and cancelled
    // in teardownLive, driving retryStartIfNeeded()/retryEndIfNeeded(). Deferred: a real
    // Task.sleep loop outlives a test's await points (tests finish in milliseconds, the
    // backoff would still be pending 2s+ later), which risks flaky/leaked Tasks retrying
    // against a torn-down fixture. retryStartIfNeeded()/retryEndIfNeeded() are the retry
    // primitives; today they're invoked synchronously by the UI's Retry buttons (Tasks 10/12).
    // Wiring the auto-backoff Task is a follow-up, not part of Task 8.

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
                displayNameProvider: @escaping @Sendable () -> String, cadence: LiveShareCadence = .init(),
                endTimeout: Duration = .seconds(4),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.backend = backend
        self.transport = transport
        self.displayNameProvider = displayNameProvider
        self.cadence = cadence
        self.endTimeout = endTimeout
        self.sleep = sleep
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
    public func startRiding() async { await attemptStart() }

    private func attemptStart() async {
        guard let rideID else { return }
        startFailed = false
        do {
            try await backend.startRide(rideID: rideID)
            phase = .riding
            pendingStart = false
        } catch {
            startFailed = true
            pendingStart = true
        }
    }

    /// Re-attempts a pending `startRiding()`. Bound to the lobby's Retry affordance (and, in
    /// production, an auto-backoff Task — see the TODO above).
    public func retryStartIfNeeded() async {
        guard pendingStart else { return }
        pendingStart = false
        await attemptStart()
    }

    /// Called by the production call sites (the lobby `.task` and the `.riding` `.task`)
    /// once a session exists: subscribes to the live transport and OWNS the event loop so
    /// this session's `ingest` (names/toasts/host-end dissolve) runs on the live stream —
    /// `RideSession.start(roster:)` would instead spawn its own loop driving only
    /// `RideSession.ingest` (dots), so the group layer would never see names/toasts live.
    /// Idempotent (the lobby and the riding view both call it); tests may still drive
    /// `tick`/`ingest` directly for the deterministic seams.
    public func beginLiveSession() async {
        guard phase != .ended else { return }
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
    /// normal member. `.rideStarted`/`.rideEnded` are optimistic lifecycle broadcasts —
    /// `.rideEnded` toasts `.hostEnded` for a guest, moves to `.ended`, and tears down the
    /// live layer. `.connected` triggers an authoritative `reconcileFromStatus()` re-read
    /// (corrects a phantom optimistic transition and re-derives host identity).
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
        case .rideStarted:
            if let current = lifecyclePhase {
                applyLifecyclePhase(optimisticPhase(.started, current: current))
            }
        case .rideEnded:
            if !isHost { toasts.append(.hostEnded) }   // preserve the guest-facing "host ended" toast
            phase = .ended
            teardownLive(session)
        case .connected:
            await reconcileFromStatus()
        default:
            break
        }
        await session.ingest(event)
        peers = session.peers
        isLive = session.isLive
    }

    /// Authoritative re-read used on connect and on foreground. Corrects a phantom optimistic
    /// transition and re-derives host identity (so a promoted host gains controls).
    public func reconcileFromStatus() async {
        guard let rideID, let current = lifecyclePhase,
              let status = try? await backend.rideStatus(rideID: rideID) else { return }
        hostID = status.hostID
        if let selfUserID { isHost = (status.hostID == selfUserID) }
        applyLifecyclePhase(authoritativePhase(status, current: current))
    }

    private func applyLifecyclePhase(_ next: RideLifecyclePhase) {
        switch next {
        case .lobby:  phase = .lobby
        case .riding: phase = .riding
        case .ended:
            phase = .ended
            teardownLive(rideSession)
        }
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

    /// Single teardown path for every dissolve (host end, member leave, host-end wire
    /// signal): stops the inner session's subscription, cancels the owned event loop and
    /// ticker, and clears `didBeginLive` so a fresh session could begin again.
    private func teardownLive(_ session: RideSession?) {
        // Clear the end/leave latches so no stale chip/pending state survives a dissolve by any
        // route (host end, member leave, wire `.rideEnded`, authoritative reconcile → `.ended`).
        endFailed = false
        pendingEnd = false
        isEnding = false
        session?.stop()
        eventLoopTask?.cancel()
        eventLoopTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        didBeginLive = false
    }
}

// MARK: - End / Leave lifecycle
//
// Split into a same-file extension purely to keep `GroupRideSession`'s primary body under
// SwiftLint's `type_body_length` ceiling; same-file access to the private stored state is
// unaffected. Behavior is identical to living in the main declaration.
extension GroupRideSession {
    public func end() async { await finishRide(.hostEnd) }

    public func endAsMember() async { await finishRide(.memberEnd) }

    public func leave() async { await finishRide(.memberLeave) }

    /// Ends (host) or leaves (member) the ride without ever faking success. `.ended` is set only
    /// when the server confirms, or when the server says the caller is already gone
    /// (`.notHost`/`.notMember`). Waited-on paths (`.hostEnd`/`.memberEnd`) show a pending state
    /// and, on a hang past `endTimeout` or any transient throw, surface `endFailed` (the Retry
    /// chip) while keeping the chrome. A keep-riding leave (`.memberLeave`) is fire-and-forget:
    /// no pending state, no chip — the rider keeps navigating solo regardless (D10).
    private func finishRide(_ intent: FinishIntent) async {
        guard let rideID else { phase = .ended; teardownLive(rideSession); return }
        let leaveOnly = (intent != .hostEnd)
        let showsFeedback = (intent != .memberLeave)
        if showsFeedback, isEnding { return }   // re-entrancy guard for waited-on paths
        // Only a waited-on path owns the retry latches. A fire-and-forget `memberLeave` must NOT
        // clobber `finishIntent`/`endFailed`/`pendingEnd` left by a prior host/member end — else a
        // later Retry would replay the wrong (keep-riding) intent and could yank a still-riding
        // member into the summary, or leave a dead chip.
        if showsFeedback {
            finishIntent = intent
            endFailed = false
            isEnding = true
        }
        defer { if showsFeedback { isEnding = false } }
        do {
            try await withTimeout(endTimeout, sleep: sleep) { [backend] in
                if leaveOnly {
                    try await backend.leaveRide(rideID: rideID)
                } else {
                    try await backend.endRide(rideID: rideID)
                }
            }
            phase = .ended
            teardownLive(rideSession)
        } catch GroupRideError.notHost, GroupRideError.notMember {
            // Already gone server-side (or a lost-response retry) — treat as success.
            phase = .ended
            teardownLive(rideSession)
        } catch {
            // TimeoutError OR any transient throw. Only a waited-on path surfaces a retry, and
            // only if the ride hasn't already ended out from under us (a racing wire `.rideEnded`
            // / reconcile can flip `.ended` while we were suspended — don't relatch).
            if showsFeedback, phase != .ended {
                endFailed = true
                pendingEnd = true
            }
        }
    }

    /// Re-attempts a pending waited-on end/leave, replaying the same intent. Bound to a Retry
    /// button (and, in production, an auto-backoff Task — see the TODO above).
    public func retryEndIfNeeded() async {
        guard pendingEnd else { return }
        pendingEnd = false
        await finishRide(finishIntent)
    }
}
