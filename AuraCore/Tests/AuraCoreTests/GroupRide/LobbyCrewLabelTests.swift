import Testing
@testable import AuraCore

struct LobbyCrewLabelTests {
    @Test func aLoneHostIsWaitingNotAOneRiderCrew() {
        #expect(LobbyCrewLabel.isWaiting(totalRows: 1))
        #expect(LobbyCrewLabel.text(totalRows: 1) == "Crew")
    }
    @Test func theCountExcludesSelf() {
        #expect(!LobbyCrewLabel.isWaiting(totalRows: 3))
        #expect(LobbyCrewLabel.text(totalRows: 3) == "Crew · 2 joined")
    }
    @Test func zeroRowsStillReadsAsWaiting() {
        #expect(LobbyCrewLabel.isWaiting(totalRows: 0))
        #expect(LobbyCrewLabel.text(totalRows: 0) == "Crew")
    }
}
