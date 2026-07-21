import Testing
import Foundation
@testable import AuraCore

struct PeerInterpolatorTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func c(_ lat: Double, _ lon: Double) -> Coordinate { Coordinate(latitude: lat, longitude: lon) }

    @Test func firstFixAppearsInPlace() {
        var i = PeerInterpolator()
        i.commit(fix: c(1, 1), recordedAt: t0, now: t0)
        #expect(i.position(at: t0) == c(1, 1))
        #expect(i.isActive(at: t0) == false)   // no tween on first fix
    }

    @Test func linearMidpointHalfwayThroughDuration() {
        var i = PeerInterpolator()
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        // second fix 2s later, ~22m east (0.0002° lon ≈ 11 m/s) — plausible, so it tweens
        i.commit(fix: c(0, 0.0002), recordedAt: t0 + 2, now: t0 + 2)
        let mid = i.position(at: t0 + 3)                    // 1s into a 2s tween
        #expect(abs(mid.longitude - 0.0001) < 1e-7)         // linear, not eased
        #expect(i.position(at: t0 + 4) == c(0, 0.0002))     // clamps at target
        #expect(i.position(at: t0 + 99) == c(0, 0.0002))    // holds (no overshoot)
        #expect(i.didSnap == false)
    }

    @Test func staleOrDuplicateRecordedAtIsIgnored() {
        var i = PeerInterpolator()
        i.commit(fix: c(0, 0), recordedAt: t0 + 10, now: t0 + 10)
        i.commit(fix: c(9, 9), recordedAt: t0 + 10, now: t0 + 11) // same recordedAt → ignore
        i.commit(fix: c(9, 9), recordedAt: t0 + 5, now: t0 + 12) // older → ignore
        #expect(i.position(at: t0 + 20) == c(0, 0))
    }

    @Test func snapsAcrossLongSilence() {
        var i = PeerInterpolator(config: .init(snapSilence: 40))
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        i.commit(fix: c(0, 0.001), recordedAt: t0 + 41, now: t0 + 41) // 41s > 40s → snap
        #expect(i.didSnap)
        #expect(i.position(at: t0 + 41) == c(0, 0.001)) // jumps, no glide
        #expect(i.bearing(at: t0 + 41) == nil)          // stale direction cleared
    }

    @Test func snapsOnImplausibleSpeedUsingRecordedAtGap() {
        // ~2200m in 2s = ~1100 m/s ≫ 25 → snap, even though gap is normal
        var i = PeerInterpolator(config: .init(maxSpeed: 25))
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        i.commit(fix: c(0.02, 0), recordedAt: t0 + 2, now: t0 + 2)
        #expect(i.didSnap)
    }

    @Test func bunchedArrivalsDoNotFalseSnap() {
        // fixes are 2s apart in recordedAt but arrive 0.05s apart in wall time.
        // Implied speed must use recordedAt gap (2s), not arrival gap.
        var i = PeerInterpolator(config: .init(maxSpeed: 25))
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0 + 10.00)
        i.commit(fix: c(0, 0.0003), recordedAt: t0 + 2, now: t0 + 10.05) // ~33m over 2s ≈ 16 m/s
        #expect(i.didSnap == false)
    }

    @Test func coincidentFixDoesNotAnimate() {
        var i = PeerInterpolator()
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        i.commit(fix: c(0, 0), recordedAt: t0 + 2, now: t0 + 2) // heartbeat: same point, fresh time
        #expect(i.isActive(at: t0 + 2) == false)                // no idle tween
        #expect(i.didSnap == false)
    }

    @Test func angularLerpTakesShortArcAcrossNorth() {
        #expect(abs(PeerInterpolator.angularLerp(350, 10, 0.5) - 0) < 1e-9)   // +20°, not -340
        #expect(abs(PeerInterpolator.angularLerp(10, 350, 0.5) - 0) < 1e-9)
    }

    @Test func bearingHoldsLastOnCoincidentCommit() {
        var i = PeerInterpolator()
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        i.commit(fix: c(0, 0.0002), recordedAt: t0 + 2, now: t0 + 2)   // moving east → bearing ≈ 90
        let b1 = i.bearing(at: t0 + 4)
        #expect(b1 != nil)
        i.commit(fix: c(0, 0.0002), recordedAt: t0 + 4, now: t0 + 4)   // heartbeat (same point)
        #expect(i.bearing(at: t0 + 4) == b1)   // holds last heading, doesn't reset/clear
    }

    @Test func isActiveTrueDuringTweenFalseAfter() {
        var i = PeerInterpolator()
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        i.commit(fix: c(0, 0.0002), recordedAt: t0 + 2, now: t0 + 2)   // 2s tween
        #expect(i.isActive(at: t0 + 3))            // mid-tween
        #expect(i.isActive(at: t0 + 5) == false)   // settled
    }

    @Test func collectionCommitsPerPeerAndPrunesLeavers() {
        let a = UUID(), b = UUID()
        var set = PeerInterpolators()
        let p1 = RidePeer(userID: a, displayName: "A", coordinate: c(0, 0),
                          lastUpdate: t0, status: .riding)
        set.commit(peers: [p1], now: t0)
        #expect(set.position(a, at: t0) == c(0, 0))
        #expect(set.position(b, at: t0) == nil)
        set.commit(peers: [], now: t0 + 1)          // A left
        #expect(set.position(a, at: t0 + 1) == nil) // pruned
    }
}
