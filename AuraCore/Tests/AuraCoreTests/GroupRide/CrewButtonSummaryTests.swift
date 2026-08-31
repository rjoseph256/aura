import Foundation
import Testing
import AuraCore

/// The compact crew button's derivations (ROH-214, revised at the review gate): the badge is
/// the whole crew's headcount; the warning fires on `.dropped` only — a stopped rider is a red
/// light, not an emergency, and every peer starts `.awaiting`, so alarming on either meant a
/// healthy ride began amber; and the display/spoken summaries lead with the same population the
/// badge shows, so the button, the expanded header, and VoiceOver can never disagree.
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

    @Test func stoppedPeerDoesNotFlagAttention() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Devon", status: .stopped)
        ])
        #expect(!summary.needsAttention)
    }

    @Test func droppedPeerFlagsAttention() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Sam", status: .dropped)
        ])
        #expect(summary.needsAttention)
    }

    @Test func awaitingPeerDoesNotFlagAttention() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Lee", status: .awaiting)
        ])
        #expect(!summary.needsAttention)
    }

    @Test func selfStatusNeverFlagsAttention() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .dropped),
            row("Priya", status: .riding)
        ])
        #expect(!summary.needsAttention)
    }

    @Test func soloCrewIsWaitingForCrew() {
        let summary = CrewButtonSummary(rows: [row("You", isSelf: true, status: .riding)])
        #expect(summary.isWaitingForCrew)
    }

    @Test func crewWithAnyPeerIsNotWaiting() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Lee", status: .awaiting)
        ])
        #expect(!summary.isWaitingForCrew)
    }

    @Test func displaySummaryLeadsWithTheBadgePopulation() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Priya", status: .riding),
            row("Marcus", status: .riding),
            row("Devon", status: .stopped)
        ])
        #expect(summary.displaySummary == "4 riders · 1 stopped")
    }

    @Test func displaySummaryCallsOutNoSignal() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Priya", status: .riding),
            row("Sam", status: .dropped)
        ])
        #expect(summary.displaySummary == "3 riders · 1 no signal")
    }

    @Test func displaySummaryCallsOutWaitingToStart() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Lee", status: .awaiting)
        ])
        #expect(summary.displaySummary == "2 riders · 1 waiting")
    }

    @Test func allRidingDisplaySummaryIsJustTheHeadcount() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Priya", status: .riding)
        ])
        #expect(summary.displaySummary == "2 riders")
    }

    @Test func soloCrewDisplaySummaryIsCrew() {
        let summary = CrewButtonSummary(rows: [row("You", isSelf: true, status: .riding)])
        #expect(summary.displaySummary == "Crew")
    }

    @Test func spokenSummarySpeaksTheHeadcountAndExceptions() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Priya", status: .riding),
            row("Devon", status: .stopped)
        ])
        #expect(summary.spokenSummary == "3 riders, 1 stopped")
    }

    @Test func spokenSummaryDistinguishesCalmFromAlarmed() {
        let calm = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Priya", status: .riding)
        ])
        let alarmed = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Priya", status: .riding),
            row("Sam", status: .dropped)
        ])
        #expect(calm.spokenSummary != alarmed.spokenSummary)
    }

    @Test func soloSpokenSummarySaysNobodyHasJoined() {
        let summary = CrewButtonSummary(rows: [row("You", isSelf: true, status: .riding)])
        #expect(summary.spokenSummary == "No riders have joined yet")
    }

    @Test func spokenSummarySpeaksWaitingToStartInFull() {
        let summary = CrewButtonSummary(rows: [
            row("You", isSelf: true, status: .riding),
            row("Lee", status: .awaiting)
        ])
        #expect(summary.spokenSummary == "2 riders, 1 waiting to start")
    }
}
