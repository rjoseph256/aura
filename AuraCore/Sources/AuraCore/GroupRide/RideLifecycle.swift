import Foundation

/// The authoritative ride lifecycle read from a durable source (join seed, reconnect
/// snapshot, foreground). `hostID` is included so a promoted host learns it is host.
public struct RideLifecycleStatus: Equatable, Sendable {
    public let hostID: UUID
    public let startedAt: Date?
    public let endedAt: Date?
    public init(hostID: UUID, startedAt: Date?, endedAt: Date?) {
        self.hostID = hostID; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// The three live phases reconciliation reasons about. `GroupRideSession.Phase` projects
/// onto this (its non-live phases don't participate).
public enum RideLifecyclePhase: Equatable, Sendable { case lobby, riding, ended }

/// A pushed lifecycle broadcast (optimistic).
public enum RideLifecycleEvent: Equatable, Sendable { case started, ended }

private func rank(_ p: RideLifecyclePhase) -> Int {
    switch p { case .lobby: return 0; case .riding: return 1; case .ended: return 2 }
}

private func naturalPhase(_ s: RideLifecycleStatus) -> RideLifecyclePhase {
    if s.endedAt != nil { return .ended }
    if s.startedAt != nil { return .riding }
    return .lobby
}

/// AUTHORITATIVE reconcile from a durable read. Applies the durable phase exactly — it
/// MAY move a rider backward (correcting a phantom optimistic start) — except `.ended`
/// is terminal and is never left.
public func authoritativePhase(_ status: RideLifecycleStatus,
                               current: RideLifecyclePhase) -> RideLifecyclePhase {
    if current == .ended { return .ended }
    return naturalPhase(status)
}

/// OPTIMISTIC reconcile from a broadcast. Only ever moves forward; a reordered/duplicate
/// event that would move a rider backward is ignored.
public func optimisticPhase(_ event: RideLifecycleEvent,
                            current: RideLifecyclePhase) -> RideLifecyclePhase {
    let target: RideLifecyclePhase = (event == .ended) ? .ended : .riding
    return rank(target) > rank(current) ? target : current
}
