import Testing
import Foundation
import AuraCore
@testable import AuraKit

private struct FixedProvider: GemProviding {
    let gems: [Gem]
    func gems(near coordinate: Coordinate) async -> [Gem] { gems }
}
private struct NeverProvider: GemProviding {
    func gems(near coordinate: Coordinate) async -> [Gem] {
        // Cancellation-AWARE stall: Task.sleep throws on cancel, so the composite's
        // group.cancelAll() unsticks it and the structured group can exit. A bare
        // withCheckedContinuation would ignore cancellation and HANG the task group.
        try? await Task.sleep(for: .seconds(3600))
        return []
    }
}

@Suite("CompositeGemProvider")
struct CompositeGemProviderTests {
    private let p = Coordinate(latitude: 40.44, longitude: -79.99)
    private func g(_ id: String, _ src: GemSource, _ c: Coordinate) -> Gem {
        Gem(id: id, name: id, coordinate: c, category: .cafe, tier: .card, source: src)
    }
    private func near(_ meters: Double) -> Coordinate {
        Coordinate(latitude: p.latitude + meters / 111_320.0, longitude: p.longitude)
    }

    @Test func unionsSources() async {
        let composite = CompositeGemProvider(
            local: [FixedProvider(gems: [g("curated:a", .curated, near(300))]),
                    FixedProvider(gems: [g("personal:b", .personal, near(600))])],
            live: FixedProvider(gems: [g("osm:node/c", .live, near(900))]))
        let ids = Set((await composite.gems(near: p)).map(\.id))
        #expect(ids == ["curated:a", "personal:b", "osm:node/c"])
    }

    @Test func dedupesSameIdKeepingHigherPriority() async {
        let composite = CompositeGemProvider(
            local: [FixedProvider(gems: [g("dup", .curated, p)]),
                    FixedProvider(gems: [g("dup", .personal, p)])],
            live: FixedProvider(gems: []))
        let gems = await composite.gems(near: p)
        #expect(gems.count == 1)
        #expect(gems.first?.source == .personal)
    }

    @Test func dedupesNearbyDifferentIdsKeepingHigherPriority() async {
        // A personal save and an OSM POI ~10 m apart = same physical spot, different ids.
        let composite = CompositeGemProvider(
            local: [FixedProvider(gems: [g("personal:x", .personal, p)])],
            live: FixedProvider(gems: [g("osm:node/y", .live, near(10))]))
        let gems = await composite.gems(near: p)
        #expect(gems.count == 1)
        #expect(gems.first?.source == .personal)
    }

    @Test func slowLiveTimesOutWithoutBlocking() async {
        let composite = CompositeGemProvider(
            local: [FixedProvider(gems: [g("curated:a", .curated, p)])],
            live: NeverProvider(),
            timeout: { /* fire immediately */ })
        let gems = await composite.gems(near: p)
        #expect(gems.map(\.id) == ["curated:a"])
    }
}
