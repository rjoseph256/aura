import Testing
import Foundation
@testable import AuraCore

@Suite("Ride activity push policy")
struct RideActivityPushPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func payload(distance: Double = 0,
                         turn: String? = nil,
                         paused: Bool = false) -> RideActivityPayload {
        RideActivityPayload(
            distanceMeters: distance,
            turnInstruction: turn,
            clock: paused ? .paused(since: t0, activeSeconds: 600) : .running(anchor: t0))
    }

    @Test("The first push always goes")
    func firstPush() {
        #expect(RideActivityPushPolicy.decide(
            last: nil, next: payload(), lastPushedAt: nil, now: t0) == .push)
    }

    @Test("An unchanged payload inside the coalescing window is skipped")
    func unchangedIsSkipped() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(), next: payload(),
            lastPushedAt: t0, now: t0.addingTimeInterval(2)) == .skip)
    }

    @Test("An unchanged payload past the coalescing window is still skipped")
    func unchangedStaysSkippedPastCoalesce() {
        // This is the dedupe: ~600 identical pushes across a 40-minute stop become heartbeats.
        #expect(RideActivityPushPolicy.decide(
            last: payload(), next: payload(),
            lastPushedAt: t0, now: t0.addingTimeInterval(30)) == .skip)
    }

    @Test("A changed payload is coalesced to the 4-second cadence")
    func changedIsCoalesced() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(distance: 1), next: payload(distance: 2),
            lastPushedAt: t0, now: t0.addingTimeInterval(2)) == .skip)
        #expect(RideActivityPushPolicy.decide(
            last: payload(distance: 1), next: payload(distance: 2),
            lastPushedAt: t0, now: t0.addingTimeInterval(4)) == .push)
    }

    @Test("A changed turn instruction bypasses the cadence")
    func turnChangeBypasses() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(turn: "Left onto Liberty"), next: payload(turn: "Right onto Penn"),
            lastPushedAt: t0, now: t0.addingTimeInterval(0.5)) == .push)
    }

    @Test("A pause bypasses the cadence, so the tap reaches the Lock Screen in the same turn")
    func pauseTransitionBypasses() {
        // Spec revision 1's fatal defect: it put this bypass nowhere, so a tap landing inside
        // the 4-second window changed nothing at all.
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: false), next: payload(paused: true),
            lastPushedAt: t0, now: t0.addingTimeInterval(0.5)) == .push)
    }

    @Test("A resume bypasses the cadence too")
    func resumeTransitionBypasses() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: false),
            lastPushedAt: t0, now: t0.addingTimeInterval(0.5)) == .push)
    }

    @Test("The heartbeat fires on an unchanged paused payload")
    func heartbeatWhilePaused() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: true),
            lastPushedAt: t0, now: t0.addingTimeInterval(59)) == .skip)
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: true),
            lastPushedAt: t0, now: t0.addingTimeInterval(60)) == .push)
    }

    @Test("The heartbeat is not gated on paused: a running ride with no new fixes stays fresh")
    func heartbeatWhileRunning() {
        // A garage start, a tunnel or a bad urban canyon yields no acceptable fixes, so the
        // payload is byte-identical for minutes. Gating the heartbeat on paused would let that
        // healthy ride go stale and tell the rider the app had died.
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: false), next: payload(paused: false),
            lastPushedAt: t0, now: t0.addingTimeInterval(60)) == .push)
    }

    @Test("The heartbeat beats the stale window, so an alive ride never dims in either state")
    func heartbeatOutrunsStaleWindow() {
        #expect(RideActivityPushPolicy.heartbeatInterval < RideActivityPushPolicy.staleInterval)
    }
}
