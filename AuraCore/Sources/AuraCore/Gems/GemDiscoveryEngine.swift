import Foundation

/// Pure, timestamp-driven discovery logic. `visiblePins` is the ambient layer;
/// `decide` adds the active layer (one tier-gated, cooldown-spaced peek at a time).
public struct GemDiscoveryEngine: Sendable {
    public let proximityRadiusMeters: Double
    public let pinCap: Int
    public let approachRadiusMeters: Double
    public let cooldownSeconds: TimeInterval

    public init(proximityRadiusMeters: Double = 1500, pinCap: Int = 10,
                approachRadiusMeters: Double = 250, cooldownSeconds: TimeInterval = 75) {
        self.proximityRadiusMeters = proximityRadiusMeters
        self.pinCap = pinCap
        self.approachRadiusMeters = approachRadiusMeters
        self.cooldownSeconds = cooldownSeconds
    }

    /// Gems within `proximityRadiusMeters` of `location`, nearest first, capped to `pinCap`.
    public func visiblePins(from candidates: [Gem], at location: Coordinate) -> [Gem] {
        candidates
            .map { ($0, Geo.distance($0.coordinate, location)) }
            .filter { $0.1 <= proximityRadiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(pinCap)
            .map(\.0)
    }

    /// Visible pins plus, if one is earned, a single gem to actively surface. Mutates
    /// `state` (records the surfaced id + `now`) only when it returns a non-nil surfacing.
    public func decide(from candidates: [Gem], at location: Coordinate,
                       now: Date, state: inout DiscoveryState) -> DiscoveryDecision {
        let pins = visiblePins(from: candidates, at: location)

        if let last = state.lastActiveAt, now.timeIntervalSince(last) < cooldownSeconds {
            return DiscoveryDecision(visiblePins: pins, activeSurfacing: nil)
        }

        let eligible = candidates
            .filter { $0.tier >= .card }
            .filter { !state.seenBefore.contains($0.id) && !state.surfacedThisRide.contains($0.id) }
            .map { ($0, Geo.distance($0.coordinate, location)) }
            .filter { $0.1 <= approachRadiusMeters }

        // Cross-source arbitration: personal > curated > live (source rank),
        // then highest tier, then nearest. Makes a personal-T3 beat a curated-T3
        // deterministically instead of falling through to distance.
        let picked = eligible.sorted { lhs, rhs in
            let lr = lhs.0.source.priorityRank, rr = rhs.0.source.priorityRank
            if lr != rr { return lr < rr }
            if lhs.0.tier != rhs.0.tier { return lhs.0.tier > rhs.0.tier }
            return lhs.1 < rhs.1
        }.first?.0

        if let gem = picked {
            state.surfacedThisRide.insert(gem.id)
            state.lastActiveAt = now
        }
        return DiscoveryDecision(visiblePins: pins, activeSurfacing: picked)
    }
}
