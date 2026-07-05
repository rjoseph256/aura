import Testing
import Foundation
@testable import AuraCore

@Suite("Engine cross-source arbitration")
struct GemDiscoveryEngineArbitrationTests {
    private let origin = Coordinate(latitude: 40.44, longitude: -79.99)
    private func at(_ meters: Double) -> Coordinate {
        Coordinate(latitude: origin.latitude + meters / 111_320.0, longitude: origin.longitude)
    }
    private func gem(_ id: String, _ source: GemSource, _ tier: GemTier, _ c: Coordinate) -> Gem {
        Gem(id: id, name: id, coordinate: c, category: .viewpoint, tier: tier, source: source)
    }

    @Test func fartherPersonalT3BeatsNearerCuratedT3() {
        let engine = GemDiscoveryEngine()
        var state = DiscoveryState()
        let candidates = [
            gem("curated:a", .curated, .cardHaptic, at(50)),
            gem("personal:b", .personal, .cardHaptic, at(200))
        ]
        let decision = engine.decide(from: candidates, at: origin, now: Date(timeIntervalSince1970: 1000), state: &state)
        #expect(decision.activeSurfacing?.id == "personal:b")
    }

    @Test func higherTierStillWinsAcrossSources() {
        let engine = GemDiscoveryEngine()
        var state = DiscoveryState()
        // curated T3 vs live T2 → curated (higher tier and higher source rank both agree)
        let candidates = [
            gem("live:x", .live, .card, at(30)),
            gem("curated:y", .curated, .cardHaptic, at(120))
        ]
        let decision = engine.decide(from: candidates, at: origin, now: Date(timeIntervalSince1970: 1000), state: &state)
        #expect(decision.activeSurfacing?.id == "curated:y")
    }

    @Test func sameSourceSameTierBreaksByNearest() {
        let engine = GemDiscoveryEngine()
        var state = DiscoveryState()
        let candidates = [
            gem("curated:far", .curated, .card, at(200)),
            gem("curated:near", .curated, .card, at(40))
        ]
        let decision = engine.decide(from: candidates, at: origin, now: Date(timeIntervalSince1970: 1000), state: &state)
        #expect(decision.activeSurfacing?.id == "curated:near")
    }
}
