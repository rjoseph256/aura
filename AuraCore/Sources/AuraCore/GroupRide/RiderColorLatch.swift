import Foundation

/// The one colour authority for a session's riders (ROH-114 §D3.3, adopted by ROH-228).
/// First assignment LATCHES: a rider's hue never changes while they remain in the session —
/// the input-set-sensitive `PeerPalette.assign` alone moves an existing rider's hue on up to a
/// quarter of membership changes (measured at `paletteCount` 8: 6.9% of existing riders for a
/// small group, rising to 25.6% once the palette is full), which is the shipped map bug this
/// replaces. Input is peers-minus-self
/// (self consumes no hue: white = me). A peer missing from an update keeps their hue
/// (staleness is not departure); `release` fires only on explicit `.memberLeft`, so a
/// force-quit rider never releases — bounded, and stated rather than hidden. The one stated
/// exception to "never changes": a rider who explicitly leaves and is later resurrected by a
/// stale `.position` re-latches a fresh hue — `.memberLeft` is authoritative departure.
///
/// Past `paletteCount` riders the palette is exhausted and hues REPEAT: the 9th rider in an
/// 8-hue session latches a duplicate of someone else's colour, permanently, like any other
/// assignment. That is intended degradation rather than a bug fixed here — the monogram is the
/// colour-independent identity cue and stays distinct — but it does mean colour alone stops
/// identifying a rider above 8. Pinned by `aNinthRiderRepeatsAHueRatherThanGoingUncoloured`.
public struct RiderColorLatch: Equatable, Sendable {
    public private(set) var assignments: [UUID: Int] = [:]
    private let paletteCount: Int

    public init(paletteCount: Int) { self.paletteCount = max(1, paletteCount) }

    public mutating func latch(peerIDs: [UUID]) {
        // Not an early-out for correctness (assign([]) already returns [:]) — this runs on every
        // peers snapshot, so on every tick, and in steady state there are no newcomers at all.
        // The guard is what keeps that path from rebuilding `Set(assignments.values)` at 1 Hz.
        let newcomers = peerIDs.filter { assignments[$0] == nil }
        guard !newcomers.isEmpty else { return }
        let fresh = PeerPalette.assign(userIDs: newcomers, paletteCount: paletteCount,
                                       reserved: Set(assignments.values))
        for (id, index) in fresh { assignments[id] = index }
    }

    public mutating func release(_ id: UUID) { assignments[id] = nil }

    public func colorIndex(for id: UUID) -> Int? { assignments[id] }
}
