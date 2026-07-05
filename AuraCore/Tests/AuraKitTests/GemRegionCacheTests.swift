import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite("GemRegionCache")
struct GemRegionCacheTests {
    private func g(_ id: String) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
            category: .cafe, tier: .card, source: .live)
    }
    private let p = Coordinate(latitude: 40.44, longitude: -79.99)

    @Test func hitWithinCellAndWindowSkipsFetch() async {
        let cache = GemRegionCache(cellMeters: 2000, stalenessSeconds: 600)
        let calls = Counter()
        _ = await cache.gems(near: p, now: Date(timeIntervalSince1970: 0)) { await calls.bump(); return [g("a")] }
        let second = await cache.gems(near: p, now: Date(timeIntervalSince1970: 100)) { await calls.bump(); return [g("b")] }
        #expect(second.map(\.id) == ["a"])          // served from cache
        #expect(await calls.value == 1)
    }

    @Test func staleWindowRefetches() async {
        let cache = GemRegionCache(cellMeters: 2000, stalenessSeconds: 600)
        let calls = Counter()
        _ = await cache.gems(near: p, now: Date(timeIntervalSince1970: 0)) { await calls.bump(); return [g("a")] }
        let second = await cache.gems(near: p, now: Date(timeIntervalSince1970: 700)) { await calls.bump(); return [g("b")] }
        #expect(second.map(\.id) == ["b"])
        #expect(await calls.value == 2)
    }

    @Test func differentCellRefetches() async {
        let cache = GemRegionCache(cellMeters: 2000, stalenessSeconds: 600)
        let calls = Counter()
        _ = await cache.gems(near: p, now: Date(timeIntervalSince1970: 0)) { await calls.bump(); return [g("a")] }
        let far = Coordinate(latitude: 41.5, longitude: -79.99)
        _ = await cache.gems(near: far, now: Date(timeIntervalSince1970: 10)) { await calls.bump(); return [g("b")] }
        #expect(await calls.value == 2)
    }
}

actor Counter { private(set) var value = 0; func bump() { value += 1 } }
