import Foundation
import AuraCore

/// Fans out to the local providers (personal, curated) concurrently plus the live provider
/// raced against a timeout, then dedupes. A slow/offline Overpass never blocks the map:
/// on timeout, live contributes []. Dedupe is two-pass — exact id, then coordinate cluster —
/// with personal > curated > live winning collisions.
public struct CompositeGemProvider: GemProviding {
    private let local: [any GemProviding]
    private let live: any GemProviding
    private let dedupeMeters: Double
    private let timeout: @Sendable () async -> Void

    /// `timeout` is `nil`-defaulted rather than given a default closure literal, and the real one
    /// is built here — see the note on `GroupRideSession.sleep` for why (ROH-110).
    ///
    /// **Prophylactic, not a diagnosed crash.** The measured abort was `GroupRideSession`'s
    /// equivalent seam. This one has the same shape — an `async` default-argument closure, raced
    /// in a group, then `cancelAll` — but its duplicated copies all measured the same size (112
    /// bytes in all three objects), so it was not miscompiled. It is changed anyway because
    /// nothing makes the sizes agree on purpose; that they matched here is luck.
    public init(local: [any GemProviding], live: any GemProviding, dedupeMeters: Double = 25,
                timeout: (@Sendable () async -> Void)? = nil) {
        self.local = local
        self.live = live
        self.dedupeMeters = dedupeMeters
        self.timeout = timeout ?? { try? await Task.sleep(for: .seconds(2)) }
    }

    public func gems(near coordinate: Coordinate) async -> [Gem] {
        async let localGems: [Gem] = withTaskGroup(of: [Gem].self) { group in
            for provider in local { group.addTask { await provider.gems(near: coordinate) } }
            var all: [Gem] = []
            for await part in group { all += part }
            return all
        }
        async let liveGems: [Gem] = livePath(near: coordinate)
        return Self.dedupe(await localGems + liveGems, within: dedupeMeters)
    }

    /// Live provider raced against the timeout. On timeout, live contributes []. Relies on
    /// the live provider being cancellation-aware (URLSession is) so `cancelAll()` unsticks
    /// the loser and the structured group can exit — a never-cancellable child would hang here.
    private func livePath(near coordinate: Coordinate) async -> [Gem] {
        await withTaskGroup(of: [Gem]?.self) { group in
            group.addTask { await live.gems(near: coordinate) }
            group.addTask { await timeout(); return nil }   // nil = timed out
            for await first in group { group.cancelAll(); return first ?? [] }
            return []
        }
    }

    /// Pass 1: exact id, higher priority wins. Pass 2: cluster within `meters`, higher priority wins.
    static func dedupe(_ gems: [Gem], within meters: Double) -> [Gem] {
        var byID: [String: Gem] = [:]
        for gem in gems {
            if let existing = byID[gem.id], existing.source.priorityRank <= gem.source.priorityRank { continue }
            byID[gem.id] = gem
        }
        var kept: [Gem] = []
        // Stable secondary key (id) so two gems of EQUAL priorityRank within `meters` of each
        // other have a deterministic survivor (lower id) instead of dictionary value order.
        for gem in byID.values.sorted(by: { lhs, rhs in
            if lhs.source.priorityRank != rhs.source.priorityRank {
                return lhs.source.priorityRank < rhs.source.priorityRank
            }
            return lhs.id < rhs.id
        }) {
            if kept.contains(where: { Geo.distance($0.coordinate, gem.coordinate) <= meters }) { continue }
            kept.append(gem)
        }
        return kept
    }
}
