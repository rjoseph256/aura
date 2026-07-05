import Foundation

/// Mutable per-ride discovery memory + the immutable cross-ride seen set.
/// `seenBefore` is seeded from persistence at ride start and never mutates during the ride.
public struct DiscoveryState: Sendable {
    public var surfacedThisRide: Set<String>
    public var lastActiveAt: Date?
    public let seenBefore: Set<String>

    public init(seenBefore: Set<String> = []) {
        self.surfacedThisRide = []
        self.lastActiveAt = nil
        self.seenBefore = seenBefore
    }
}

/// What the engine decided for one location sample: the visible pins, and at most
/// one gem to actively surface (peek card / haptic) right now.
public struct DiscoveryDecision: Sendable, Equatable {
    public let visiblePins: [Gem]
    public let activeSurfacing: Gem?
    public init(visiblePins: [Gem], activeSurfacing: Gem?) {
        self.visiblePins = visiblePins
        self.activeSurfacing = activeSurfacing
    }
}
