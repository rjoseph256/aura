import Foundation
import Testing
import AuraCore
@testable import AuraKit

@Suite struct CuratedGemProviderTests {
    @Test func loadsAndDecodesTheRealDataset() async {
        let gems = await CuratedGemProvider().gems(near: Coordinate(latitude: 40.44, longitude: -80.0))
        #expect(gems.count >= 140)
        #expect(gems.allSatisfy { $0.source == .curated })
        #expect(gems.contains { $0.id == "curated:grandview-overlook" && $0.tier == .cardHaptic })
        #expect(Set(gems.map(\.id)).count == gems.count)   // ids unique
    }

    @Test func tierThreeIsRareAndEarned() async {
        let gems = await CuratedGemProvider().gems(near: Coordinate(latitude: 40.44, longitude: -80.0))
        let t3 = gems.filter { $0.tier == .cardHaptic }
        #expect(t3.count >= 12 && t3.count <= 20)   // rare but present
        // No two Tier-3 within 1.5km (haptic clustering guard, mirrors build_gems.py).
        for i in t3.indices { for j in t3.indices where j > i {
            #expect(Geo.distance(t3[i].coordinate, t3[j].coordinate) >= 1500)
        } }
    }

    @Test func tierDistributionMatchesRubric() async {
        let gems = await CuratedGemProvider().gems(near: Coordinate(latitude: 40.44, longitude: -80.0))
        let total = Double(gems.count)
        let t2 = Double(gems.filter { $0.tier == .card }.count)
        let t1 = Double(gems.filter { $0.tier == .pin }.count)
        #expect(t2 / total >= 0.50)                 // Tier-2 is the majority
        #expect(t1 / total <= 0.35)                 // Tier-1 is quiet filler, not the bulk
        #expect(Set(gems.map(\.category)).count == GemCategory.allCases.count)  // all 8 categories present
    }

    // Coverage checklist (spec §3 P6) — anchored to stable slugs the author must include.
    @Test func coverageChecklistAnchorsArePresent() async {
        let gems = await CuratedGemProvider().gems(near: Coordinate(latitude: 40.44, longitude: -80.0))
        let ids = Set(gems.map(\.id))
        let required = [
            "curated:grandview-overlook", "curated:west-end-overlook",   // viewpoints
            "curated:point-state-park",                                  // water
            "curated:schenley-park", "curated:frick-park", "curated:riverview-park", // parks
            "curated:randyland",                                         // mural
            "curated:canton-avenue",                                     // climb (world's steepest)
            "curated:duquesne-incline", "curated:mattress-factory",      // historic
            "curated:cathedral-of-learning", "curated:national-aviary",  // landmarks
        ]
        for id in required { #expect(ids.contains(id), "missing required gem \(id)") }
    }

    @Test func dropsMalformedEntriesRatherThanThrowing() async {
        let okEntry = #"{"id":"ok","name":"Ok","coordinate":{"latitude":1,"longitude":2},"#
            + #""category":"park","tier":2,"source":"curated"}"#
        let badEntry = #"{"id":"bad","name":"Bad","coordinate":{"latitude":1,"longitude":2},"#
            + #""category":"NOT_A_CATEGORY","tier":2,"source":"curated"}"#
        let bad = "[\(okEntry),\(badEntry)]"
        let gems = CuratedGemProvider.decode(Data(bad.utf8))
        #expect(gems.map(\.id) == ["ok"])
    }
}
