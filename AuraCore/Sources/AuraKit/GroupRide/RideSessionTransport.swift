import Foundation
import AuraCore

/// One event on a ride's live channel. The `.connected`/`.disconnected` arms let the
/// session distinguish "peer is quiet" (a staleness/tick condition) from "my socket
/// dropped" (handled by the transport's own reconnect); `.disconnected` carries the
/// cause for the non-fatal "live sharing unavailable" surface.
public enum TransportEvent: Sendable {
    case position(LivePositionPayload)
    case memberLeft(UUID)
    case connected
    // `any Error & Sendable` (not bare `Error?`): a non-Sendable associated value would
    // block the synthesized `Sendable` conformance, and this enum crosses the
    // nonisolated -> @MainActor boundary. The conformer maps caught errors to a Sendable
    // error type (see Task 16's LiveTransportError).
    case disconnected((any Error & Sendable)?)
}

/// One owned subscription to a ride's live channel. Owning the channel in a single
/// object (mirroring `LocationStreaming`) means teardown is unambiguous: `cancel()`
/// (or deinit) finishes the stream and releases the channel. There is no separate
/// keyed unsubscribe to leak.
@MainActor
public protocol RideLiveSubscription: AnyObject {
    var events: AsyncStream<TransportEvent> { get }
    func cancel()
}

/// The live-transport seam. The live conformer (Supabase) lives in the app target;
/// tests inject `InMemoryRideSessionTransport`. Reconnect/backoff lives inside the
/// conformer and surfaces as `.connected`/`.disconnected` events.
public protocol RideSessionTransport: Sendable {
    @MainActor func liveSubscription(rideID: UUID) -> any RideLiveSubscription
    func snapshot(rideID: UUID) async throws -> [LivePositionPayload]
    func publish(rideID: UUID, points: [LivePositionPayload]) async throws
}

/// Deterministic in-memory transport for tests. `emit(_:)` drives the subscription
/// stream; `snapshotResult` is returned by `snapshot`; `publishedBatches` records
/// every `publish`.
@MainActor
public final class InMemoryRideSessionTransport: RideSessionTransport {
    public var snapshotResult: [LivePositionPayload] = []
    public private(set) var publishedBatches: [[LivePositionPayload]] = []

    @MainActor
    private final class Subscription: RideLiveSubscription {
        let events: AsyncStream<TransportEvent>
        let continuation: AsyncStream<TransportEvent>.Continuation
        init() {
            var cont: AsyncStream<TransportEvent>.Continuation!
            events = AsyncStream { cont = $0 }
            continuation = cont
        }
        func cancel() { continuation.finish() }
    }

    private var current: Subscription?

    public init() {}

    public func liveSubscription(rideID: UUID) -> any RideLiveSubscription {
        let sub = Subscription()
        current = sub
        return sub
    }

    /// Push an event to the most-recently-created subscription (test driver).
    public func emit(_ event: TransportEvent) {
        current?.continuation.yield(event)
    }

    public func snapshot(rideID: UUID) async throws -> [LivePositionPayload] { snapshotResult }

    public func publish(rideID: UUID, points: [LivePositionPayload]) async throws {
        publishedBatches.append(points)
    }
}
