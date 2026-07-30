import Testing
import Foundation
@testable import AuraCore

@Suite("Ride activity payload")
struct RideActivityPayloadTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func running(distance: Double) -> RideActivityPayload {
        RideActivityPayload(distanceMeters: distance, clock: .running(anchor: start))
    }

    @Test("Two payloads with the same values are equal, so the dedupe can key on them")
    func equalityIsByValue() {
        #expect(running(distance: 100) == running(distance: 100))
        #expect(running(distance: 100) != running(distance: 101))
    }

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        let payload = RideActivityPayload(
            distanceMeters: 1234.5, speedMetersPerSecond: 6.1, elevationGainMeters: 42,
            turnInstruction: "Right onto Penn Ave", turnDistanceMeters: 120,
            turnGlyphSystemName: "arrow.turn.up.right",
            clock: .paused(since: start, activeSeconds: 600))
        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(RideActivityPayload.self, from: data) == payload)
    }

    @Test("A paused payload holds the turn it had before the stop")
    func pausedHoldsPreviousTurn() {
        // GuidanceViewModel.applyProgress updates lastUpdate before its isPaused guard, so a
        // stationary rider's distance-to-turn drifts with GPS jitter. Left alone it ticks beside
        // a frozen clock and defeats the dedupe on every navigate pause (spec D7).
        let before = RideActivityPayload(turnInstruction: "Right onto Penn Ave",
                                         turnDistanceMeters: 120,
                                         turnGlyphSystemName: "arrow.turn.up.right",
                                         clock: .running(anchor: start))
        let drifted = RideActivityPayload(turnInstruction: "Right onto Penn Ave",
                                          turnDistanceMeters: 117,
                                          turnGlyphSystemName: "arrow.turn.up.right",
                                          clock: .paused(since: start, activeSeconds: 600))
        let held = drifted.holdingTurn(from: before)
        #expect(held.turnDistanceMeters == 120)
        #expect(held.turnInstruction == "Right onto Penn Ave")
        #expect(held.clock == drifted.clock)
    }

    @Test("Holding is stable, so successive paused ticks stay equal")
    func holdingIsStableAcrossTicks() {
        let before = RideActivityPayload(turnDistanceMeters: 120, clock: .running(anchor: start))
        var previous = before
        var held: [RideActivityPayload] = []
        for drift in [117.0, 114.0, 119.0] {
            let tick = RideActivityPayload(turnDistanceMeters: drift,
                                           clock: .paused(since: start, activeSeconds: 600))
                .holdingTurn(from: previous)
            held.append(tick)
            previous = tick
        }
        #expect(Set(held).count == 1)
    }

    @Test("A running payload keeps its own turn")
    func runningKeepsItsOwnTurn() {
        let before = RideActivityPayload(turnDistanceMeters: 120, clock: .running(anchor: start))
        let next = RideActivityPayload(turnDistanceMeters: 90, clock: .running(anchor: start))
        #expect(next.holdingTurn(from: before).turnDistanceMeters == 90)
    }

    @Test("A pause with no previous payload holds nothing")
    func pausedWithNoPreviousIsUnchanged() {
        let paused = RideActivityPayload(turnDistanceMeters: 90,
                                         clock: .paused(since: start, activeSeconds: 600))
        #expect(paused.holdingTurn(from: nil) == paused)
    }
}
