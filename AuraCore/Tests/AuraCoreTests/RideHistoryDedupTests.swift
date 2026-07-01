import Testing
import Foundation
@testable import AuraCore

struct RideHistoryDedupTests {
    private struct Row { let id: UUID; let tag: String }

    @Test func keepsFirstOccurrenceOfEachID() {
        let a = UUID(); let b = UUID()
        let rows = [Row(id: a, tag: "newest"), Row(id: b, tag: "other"), Row(id: a, tag: "older")]
        let out = RideHistoryDedup.unique(rows, by: \.id)
        #expect(out.map(\.tag) == ["newest", "other"])
    }

    @Test func leavesDistinctIDsUntouched() {
        let rows = [Row(id: UUID(), tag: "x"), Row(id: UUID(), tag: "y")]
        #expect(RideHistoryDedup.unique(rows, by: \.id).count == 2)
    }
}
