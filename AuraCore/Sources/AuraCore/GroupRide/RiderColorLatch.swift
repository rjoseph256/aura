import Foundation

/// The one colour authority for a session's riders (ROH-114 §D3.3, adopted by ROH-228).
/// First assignment LATCHES: a rider's hue never changes while they remain in the session —
/// the input-set-sensitive `PeerPalette.assign` alone moves an existing rider's hue on up to a
/// quarter of membership changes (measured at `paletteCount` 8: 6.9% of existing riders for a
/// small group, rising to 25.6% once the palette is full), which is the shipped map bug this
/// replaces. Input is peers-minus-self
/// (self consumes no hue: white = me). A peer missing from an update keeps their hue
/// (staleness is not departure); `release` fires only on explicit `.memberLeft`, so a
/// force-quit rider never releases — bounded, and stated rather than hidden. A released rider
/// who reappears re-latches a fresh hue, because "newcomer" here means only "not currently in
/// `assignments`" — nothing distinguishes never-seen from seen-and-departed. That happens on a
/// stale `.position`, and also when the lobby's roster poll races the `.memberLeft` broadcast
/// and re-adds the departed rider (the presence merge is additive-only and keeps no departure
/// tombstone — ROH-232). So `.memberLeft` is authoritative departure by convention, not by any
/// guard in this type.
///
/// Past `paletteCount` riders the palette is exhausted and hues REPEAT: a 9th rider in an
/// 8-hue session would latch a duplicate of someone else's colour, permanently, like any
/// other assignment. It degrades rather than breaks — the monogram is the colour-independent
/// cue and stays distinct — and it is unreachable through a legitimate join: `join_ride`
/// caps a ride at 8 members INCLUDING the host (`0014_join_cap_lock.sql`, still enforced at
/// `0021_open_rides.sql`), so peers-minus-self never exceeds 7 and the palette carries one
/// spare slot. The behaviour is pinned anyway by
/// `aNinthRiderRepeatsAHueRatherThanGoingUncoloured`, because the cap lives in SQL and this
/// type must not silently depend on it.
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
