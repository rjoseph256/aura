import Testing
import Foundation
@testable import AuraCore

@Suite struct GemDiscoveryDecisionTests {
    private let here = Coordinate(latitude: 40.4406, longitude: -79.9959)
    private func gem(_ id: String, _ lat: Double, tier: GemTier) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: lat, longitude: -79.9959),
            category: .park, tier: tier, source: .curated)
    }
    // ~ meters north of `here` per 0.0001 lat ≈ 11.1 m
    private func near(_ id: String, meters: Double, tier: GemTier) -> Gem {
        gem(id, 40.4406 + meters / 111_320.0, tier: tier)
    }
    private let engine = GemDiscoveryEngine(proximityRadiusMeters: 1500, pinCap: 10,
                                            approachRadiusMeters: 250, cooldownSeconds: 75)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func surfacesTier2WithinApproachRadius() {
        var state = DiscoveryState()
        let d = engine.decide(from: [near("a", meters: 100, tier: .card)], at: here, now: t0, state: &state)
        #expect(d.activeSurfacing?.id == "a")
        #expect(state.surfacedThisRide.contains("a"))
        #expect(state.lastActiveAt == t0)
    }

    @Test func tier1PinsNeverActivelySurface() {
        var state = DiscoveryState()
        let d = engine.decide(from: [near("p", meters: 50, tier: .pin)], at: here, now: t0, state: &state)
        #expect(d.activeSurfacing == nil)
        #expect(d.visiblePins.map(\.id) == ["p"]) // still a visible pin
    }

    @Test func respectsApproachRadius() {
        var state = DiscoveryState()
        let d = engine.decide(from: [near("far", meters: 800, tier: .cardHaptic)], at: here, now: t0, state: &state)
        #expect(d.activeSurfacing == nil)          // outside 250 m approach…
        #expect(d.visiblePins.map(\.id) == ["far"]) // …but inside 1500 m pin radius
    }

    @Test func cooldownBlocksASecondSurfacingTooSoon() {
        var state = DiscoveryState()
        _ = engine.decide(from: [near("a", meters: 100, tier: .card)], at: here, now: t0, state: &state)
        let d = engine.decide(from: [near("b", meters: 120, tier: .card)], at: here,
                              now: t0.addingTimeInterval(30), state: &state)
        #expect(d.activeSurfacing == nil)           // 30 s < 75 s cooldown
        let later = engine.decide(from: [near("b", meters: 120, tier: .card)], at: here,
                                  now: t0.addingTimeInterval(80), state: &state)
        #expect(later.activeSurfacing?.id == "b")   // 80 s ≥ cooldown
    }

    @Test func doesNotRepeatWithinRideOrAcrossRides() {
        var seen = DiscoveryState(seenBefore: ["b"])
        let d1 = engine.decide(from: [near("b", meters: 100, tier: .card)], at: here, now: t0, state: &seen)
        #expect(d1.activeSurfacing == nil)          // seen on a prior ride → quiet
        var fresh = DiscoveryState()
        _ = engine.decide(from: [near("a", meters: 100, tier: .card)], at: here, now: t0, state: &fresh)
        let again = engine.decide(from: [near("a", meters: 100, tier: .card)], at: here,
                                  now: t0.addingTimeInterval(200), state: &fresh)
        #expect(again.activeSurfacing == nil)       // already surfaced this ride
    }

    @Test func picksHighestTierThenNearest() {
        var state = DiscoveryState()
        let d = engine.decide(from: [near("card-close", meters: 40, tier: .card),
                                     near("haptic-far", meters: 200, tier: .cardHaptic),
                                     near("haptic-near", meters: 150, tier: .cardHaptic)],
                              at: here, now: t0, state: &state)
        #expect(d.activeSurfacing?.id == "haptic-near") // highest tier, nearest of that tier
    }
}
