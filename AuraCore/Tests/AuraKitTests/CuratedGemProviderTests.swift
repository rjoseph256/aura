import Foundation
import Testing
import AuraCore
@testable import AuraKit

@Suite struct CuratedGemProviderTests {
    @Test func loadsAndDecodesTheBundledSeed() async {
        let gems = await CuratedGemProvider().gems(near: Coordinate(latitude: 40.44, longitude: -80.0))
        #expect(gems.count >= 3)
        #expect(gems.contains { $0.id == "curated:grandview-overlook" && $0.tier == .cardHaptic })
        #expect(gems.allSatisfy { $0.source == .curated })
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
