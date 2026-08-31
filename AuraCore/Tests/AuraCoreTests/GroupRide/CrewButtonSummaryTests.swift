import Foundation
import Testing
import AuraCore

/// The compact crew button's derivations (ROH-214): the badge is the whole crew's headcount,
/// attention tracks any non-self peer who is not actively riding, and the text summaries are
/// the ones the old collapsed bar displayed/spoke (moved here from the view so the button,
/// the expanded header, and VoiceOver all read from one derivation).
struct CrewButtonSummaryTests {
    private func row(_ name: String, isSelf: Bool = false, status: PeerStatus,
                     distance: String? = nil) -> RosterRow {
        RosterRow(id: UUID(), name: name, isSelf: isSelf, status: status, distanceLabel: distance)
    }

    @Test func badgeCountsTheWholeCrewIncludingSelf() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Priya", status: .riding),
            row("Marcus", status: .stopped)
        ])
        #expect(summary.riderCount == 3)
    }

    @Test func allRidingNeedsNoAttention() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Priya", status: .riding)
        ])
        #expect(!summary.needsAttention)
    }

    @Test func stoppedPeerFlagsAttention() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Devon", status: .stopped)
        ])
        #expect(summary.needsAttention)
    }

    @Test func droppedPeerFlagsAttention() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Sam", status: .dropped)
        ])
        #expect(summary.needsAttention)
    }

    @Test func awaitingPeerFlagsAttention() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Lee", status: .awaiting)
        ])
        #expect(summary.needsAttention)
    }

    @Test func selfStatusNeverFlagsAttention() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .stopped),
            row("Priya", status: .riding)
        ])
        #expect(!summary.needsAttention)
    }

    @Test func displaySummaryJoinsRidingAndStoppedClauses() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Priya", status: .riding),
            row("Marcus", status: .riding),
            row("Devon", status: .stopped)
        ])
        #expect(summary.displaySummary == "2 riding · 1 stopped")
    }

    @Test func displaySummaryFallsBackToNoSignalWhenThatIsTheOnlyClause() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Sam", status: .dropped)
        ])
        #expect(summary.displaySummary == "1 no signal")
    }

    @Test func soloCrewSummaryIsCrew() {
        let summary = CrewButtonSummary(rows: [row("You", isSelf: true, status: .riding)])
        #expect(summary.displaySummary == "Crew")
    }
}
