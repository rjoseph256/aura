import Testing
import Foundation
@testable import AuraCore

/// Guards the ride HUD control-button sizing invariants (ROH-75). A moving, one-handed,
/// possibly gloved rider on a vibrating bar mount needs a tap target well above Apple's
/// 44 pt floor, while the drawn circle stays light over the map — so the tap region is
/// allowed to grow past the visual, but never to shrink inside it.
struct HUDControlMetricsTests {
    @Test func standardSitsAtTheFloor() {
        // Stationary chrome (Home, route preview, back chevron) stays at the 44 pt minimum.
        #expect(HUDControlMetrics.standard.size == 44)
        #expect(HUDControlMetrics.standard.resolvedHitTarget == 44)
    }

    @Test func rideKeepsTheLightVisualWeightAndGrowsOnlyTheTapTarget() {
        // The whole point of ROH-75: the drawn circle stays at the light 44 pt weight over the
        // map, while the tap region grows well past the 44 pt floor. Pinning both concrete
        // numbers guards against a regression that makes the controls visually heavier
        // (size > 44) or quietly drops the tap region back toward the floor.
        #expect(HUDControlMetrics.ride.size == 44)
        #expect(HUDControlMetrics.ride.hitTarget == 56)
        #expect(HUDControlMetrics.ride.resolvedHitTarget >= 56)
    }

    @Test func hitTargetClampsUpToTheVisualSize() {
        // A misconfigured preset with a hit target smaller than the circle resolves to the
        // circle, so the invariant holds for any future preset — not just the shipped ones.
        let clamped = HUDControlMetrics(size: 52, hitTarget: 40)
        #expect(clamped.resolvedHitTarget == 52)
    }

    @Test func everyPresetIsAtLeastTheAppleFloor() {
        for metrics in [HUDControlMetrics.standard, .ride] {
            #expect(metrics.resolvedHitTarget >= 44)
            #expect(metrics.size >= 44)
        }
    }
}
