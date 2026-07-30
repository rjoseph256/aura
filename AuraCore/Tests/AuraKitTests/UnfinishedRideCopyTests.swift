import Testing
import Foundation
@testable import AuraKit

/// The copy is the whole feature, so it is pinned here rather than left to a view.
@Suite("Unfinished-ride copy")
struct UnfinishedRideCopyTests {
    private let cal = Calendar(identifier: .gregorian)
    private let stamp = Date(timeIntervalSince1970: 1_750_000_000)

    /// The detail line has to do the job schema V7 was bought for: separate "you forgot to
    /// press End" from "40 km are missing". "Recorded until X" reads as "the recording ran to
    /// the end" and does neither, so the string must say what was lost, not just when.
    @Test func theDetailSaysWhatWasNotSaved() throws {
        let detail = try #require(UnfinishedRideCopy.detail(checkpointedAt: stamp,
                                                            relativeTo: stamp, calendar: cal))
        #expect(detail.contains("wasn't saved"))
    }

    /// A PR #90 dev-build row has no marker timestamp, so there is nothing honest to say
    /// beyond the label.
    @Test func detailIsNilWithoutATimestamp() {
        #expect(UnfinishedRideCopy.detail(checkpointedAt: nil,
                                          relativeTo: stamp, calendar: cal) == nil)
    }

    /// A stop from an earlier day needs its date, or a bare "2:14 PM" is ambiguous.
    @Test func anEarlierDayCarriesItsDate() throws {
        let later = stamp.addingTimeInterval(3 * 86_400)
        let sameDay = try #require(UnfinishedRideCopy.detail(checkpointedAt: stamp,
                                                             relativeTo: stamp, calendar: cal))
        let otherDay = try #require(UnfinishedRideCopy.detail(checkpointedAt: stamp,
                                                              relativeTo: later, calendar: cal))
        #expect(otherDay.count > sameDay.count)
    }

    /// The delete warning must not claim the recording is complete. A rider who paused at
    /// km 20, resumed and was killed at km 60 loses 40 km, and this dialog is the last thing
    /// they read before an irreversible, all-devices delete.
    @Test func theDeleteWarningDoesNotPromiseEverythingWasSaved() {
        let warning = UnfinishedRideCopy.deleteWarning(checkpointedAt: stamp,
                                                       relativeTo: stamp, calendar: cal)
        #expect(warning.contains("wasn't saved"))
        #expect(!warning.lowercased().contains("everything"))
        #expect(warning.contains("all your devices"))
    }

    @Test func theDeleteWarningWorksWithoutATimestamp() {
        let warning = UnfinishedRideCopy.deleteWarning(checkpointedAt: nil,
                                                       relativeTo: stamp, calendar: cal)
        #expect(!warning.isEmpty)
        #expect(warning.contains("all your devices"))
    }

    @Test func theAccessibilityLabelCarriesBothParts() {
        let spoken = UnfinishedRideCopy.accessibilityLabel(checkpointedAt: stamp,
                                                           relativeTo: stamp, calendar: cal)
        #expect(spoken.contains(UnfinishedRideCopy.label))
        #expect(spoken.contains("wasn't saved"))
    }
}
