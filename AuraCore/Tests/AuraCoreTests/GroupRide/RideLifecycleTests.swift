import Foundation
import Testing
@testable import AuraCore

struct RideLifecycleTests {
    private func status(started: Bool, ended: Bool) -> RideLifecycleStatus {
        RideLifecycleStatus(hostID: UUID(),
                            startedAt: started ? Date(timeIntervalSince1970: 10) : nil,
                            endedAt: ended ? Date(timeIntervalSince1970: 20) : nil)
    }

    // authoritative: exact match, ended dominates started dominates lobby
    @Test func authoritativeLobbyWhenNeither() {
        #expect(authoritativePhase(status(started: false, ended: false), current: .lobby) == .lobby)
    }
    @Test func authoritativeRidingWhenStarted() {
        #expect(authoritativePhase(status(started: true, ended: false), current: .lobby) == .riding)
    }
    @Test func authoritativeEndedWhenEnded() {
        #expect(authoritativePhase(status(started: true, ended: true), current: .riding) == .ended)
    }
    // authoritative CORRECTS a phantom optimistic riding back to lobby (the key fix)
    @Test func authoritativeCorrectsPhantomStart() {
        #expect(authoritativePhase(status(started: false, ended: false), current: .riding) == .lobby)
    }
    // authoritative never leaves ended, even if a stale read disagrees
    @Test func authoritativeEndedIsTerminal() {
        #expect(authoritativePhase(status(started: false, ended: false), current: .ended) == .ended)
    }

    // optimistic: only moves forward
    @Test func optimisticStartMovesLobbyToRiding() {
        #expect(optimisticPhase(.started, current: .lobby) == .riding)
    }
    @Test func optimisticEndMovesRidingToEnded() {
        #expect(optimisticPhase(.ended, current: .riding) == .ended)
    }
    @Test func optimisticStartNeverUnEnds() {
        #expect(optimisticPhase(.started, current: .ended) == .ended)   // reordered start after end
    }
    @Test func optimisticEndFromLobbyGoesEnded() {
        #expect(optimisticPhase(.ended, current: .lobby) == .ended)     // host ends before starting
    }
}
