import Testing
import Foundation
@testable import AuraCore

@Suite("GemSource priority")
struct GemSourceTests {
    @Test func personalOutranksCuratedOutranksLive() {
        #expect(GemSource.personal.priorityRank < GemSource.curated.priorityRank)
        #expect(GemSource.curated.priorityRank < GemSource.live.priorityRank)
    }
}
