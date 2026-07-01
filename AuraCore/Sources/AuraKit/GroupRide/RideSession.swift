import Foundation
import AuraCore

/// The point handoff from the ride's single location stream into the group session.
/// `RideSessionCoordinator` (the sole stream owner) pushes points here; the session
/// never opens its own location stream (AsyncStream is single-consumer).
@MainActor
public protocol GroupLocationSink: AnyObject {
    func locationDidUpdate(coordinate: Coordinate, progressMeters: Double, speed: Double, at: Date)
}

/// The live group session: owns the receiver-side `LivePresenceState` and the local
/// outbox, consumes transport events, and publishes the rider's own points on a cadence.
/// Thin by design — all logic lives in the pure AuraCore types. Time is injected via
/// `publishIfDue(now:)` / `stalenessTick(now:)` (the owner's ticker supplies it), so the
/// session contains no `Date()` and no `Task.sleep`.
@MainActor
public final class RideSession: GroupLocationSink {
    private let rideID: UUID
    private let selfUserID: UUID
    private let transport: any RideSessionTransport
    private let cadence: LiveShareCadence
    private let classifier: MotionClassifier

    private var presence: LivePresenceState
    private var outbox = PointOutbox()
    private var subscription: (any RideLiveSubscription)?
    private var eventTask: Task<Void, Never>?

    private var speedSamples: [SpeedSample] = []
    private var ownMotion: MotionState = .moving
    private var lastPublish: Date = .distantPast

    /// Live-sharing health, for a non-fatal "unavailable" surface (SP3 reads it).
    public private(set) var isLive = false

    public init(rideID: UUID, selfUserID: UUID, transport: any RideSessionTransport,
                cadence: LiveShareCadence = .init()) {
        self.rideID = rideID
        self.selfUserID = selfUserID
        self.transport = transport
        self.cadence = cadence
        self.classifier = MotionClassifier(stoppedSpeed: cadence.stoppedSpeed,
                                           stoppedDuration: cadence.stoppedDuration)
        self.presence = LivePresenceState(roster: [], droppedTimeout: cadence.droppedTimeout)
    }

    public var peers: [RidePeer] { presence.peers }

    public func start(roster: [RidePeer]) async {
        presence = LivePresenceState(roster: roster, droppedTimeout: cadence.droppedTimeout)
        let sub = transport.liveSubscription(rideID: rideID)
        subscription = sub
        eventTask = Task { [weak self] in
            for await event in sub.events {
                await self?.ingest(event)
            }
        }
    }

    /// Like `start(roster:)`, but does NOT spawn the internal event loop — it seeds the
    /// roster, opens the subscription (stored so `stop()` still cancels it), and hands the
    /// event stream back to the caller. `GroupRideSession` uses this so IT owns the loop
    /// and its own `ingest` (names/toasts/host-end dissolve) runs on the live stream,
    /// rather than only `RideSession.ingest` (dots) as with `start(roster:)`.
    public func startManaged(roster: [RidePeer]) -> AsyncStream<TransportEvent> {
        presence = LivePresenceState(roster: roster, droppedTimeout: cadence.droppedTimeout)
        let sub = transport.liveSubscription(rideID: rideID)
        subscription = sub
        return sub.events
    }

    /// The deterministic event seam. The production event task and the tests both call
    /// this; tests call it directly so event handling needs no `Task.sleep` to settle.
    public func ingest(_ event: TransportEvent) async {
        switch event {
        case .position(let payload):
            presence.apply(payload, now: payload.recordedAt)
        case .memberLeft(let userID):
            presence.remove(userID: userID)
        case .connected:
            isLive = true
            await reseed()
        case .disconnected:
            isLive = false
        }
    }

    private func reseed() async {
        guard let rows = try? await transport.snapshot(rideID: rideID) else { return }
        for row in rows { presence.apply(row, now: row.recordedAt) }
    }

    // MARK: GroupLocationSink

    public func locationDidUpdate(coordinate: Coordinate, progressMeters: Double,
                                  speed: Double, at: Date) {
        speedSamples.append(SpeedSample(speed: speed, at: at))
        let cutoff = at.addingTimeInterval(-cadence.stoppedDuration * 2)
        speedSamples.removeAll { $0.at < cutoff }
        ownMotion = classifier.classify(speedSamples, now: at)
        outbox.add(LivePositionPayload(userID: selfUserID, coordinate: coordinate,
                                       progressMeters: progressMeters, recordedAt: at,
                                       motionState: ownMotion))
    }

    /// Called by the owner's ticker. Publishes the buffered own-points when the cadence
    /// interval (for the current motion + lifecycle) has elapsed.
    public func publishIfDue(now: Date, lifecycle: RideLifecycle) async {
        guard !outbox.isEmpty else { return }
        // Duration -> seconds WITHOUT truncation. `.components.seconds` is whole seconds
        // only, so a sub-second foregroundInterval (the spec's "lowerable to ~1s") would
        // otherwise collapse to 0 and defeat the throttle.
        let c = cadence.interval(for: ownMotion, lifecycle: lifecycle).components
        let interval = Double(c.seconds) + Double(c.attoseconds) / 1e18
        guard now.timeIntervalSince(lastPublish) >= interval else { return }
        let batch = outbox.drain()
        lastPublish = now
        do {
            try await transport.publish(rideID: rideID, points: batch)
        } catch {
            // Re-buffer on failure; the next due tick retries.
            for point in batch { outbox.add(point) }
        }
    }

    /// Called by the owner's ticker to age silent peers to `dropped`.
    public func stalenessTick(now: Date) {
        presence.tick(now: now)
    }

    public func stop() {
        eventTask?.cancel(); eventTask = nil
        subscription?.cancel(); subscription = nil
        isLive = false
    }
}
