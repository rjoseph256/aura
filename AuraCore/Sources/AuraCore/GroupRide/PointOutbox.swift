import Foundation

/// Buffers the local rider's own unsent points across network gaps. Flushed through
/// record_track_points when the network returns, healing the durable trail independently
/// of the live socket. Bounded so a long dead zone cannot grow memory without limit;
/// the oldest points are dropped first (the durable trail is approximate across very
/// long gaps, and the post-ride summary draws from whatever did land).
public struct PointOutbox: Sendable {
    private var pending: [LivePositionPayload] = []
    private let capacity: Int

    public init(capacity: Int = 1000) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { pending.isEmpty }
    public var count: Int { pending.count }

    public mutating func add(_ payload: LivePositionPayload) {
        pending.append(payload)
        if pending.count > capacity {
            pending.removeFirst(pending.count - capacity)
        }
    }

    public mutating func drain() -> [LivePositionPayload] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
