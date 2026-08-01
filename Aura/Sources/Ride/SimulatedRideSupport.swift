import SwiftUI
import AuraCore
import AuraKit

/// Golden-ride harness support shared by both HUDs (ROH-92/ROH-93). Inert in Release:
/// the ride override is compiled out entirely and the probe modifier passes content
/// through unchanged.
enum SimulatedRideSupport {
    #if DEBUG
    /// (fixture location stream, .authorized) when the harness is active, else nil.
    /// Both HUDs pass these straight into `coordinator.start`, so the two ride paths
    /// provably feed the coordinator identical simulated input.
    @MainActor
    static func rideOverride() -> (location: any LocationStreaming,
                                   authorization: LocationAuthorization)? {
        guard let sim = SimulatedRideConfig.current else { return nil }
        do {
            // The name is validated in `SimulatedRideConfig.parse`, so `current` being
            // non-nil already means the lookup knows it; the nil branch below is
            // unreachable and asserts rather than riding on real GPS.
            guard let provider = try SimulatedRideFixture.provider(
                named: sim.fixture, multiplier: sim.speedMultiplier) else {
                assertionFailure("Simulated ride fixture not in the registry: \(sim.fixture)")
                return nil
            }
            return (provider, .authorized)
        } catch {
            // Defensive-only: the fixture is always bundled; a packaging regression
            // fails loudly in Debug instead of silently riding on GPS.
            assertionFailure("Simulated ride fixture failed to load: \(error)")
            return nil
        }
    }
    #endif
}

/// Invisible machine-readable stats line for the golden-ride tests. Renders only in
/// DEBUG simulated rides and never intercepts touches — the navigate End button lives
/// in the same bottom region the overlay anchors to.
private struct SimulatedRideProbe: ViewModifier {
    let distanceMeters: Double
    let elapsed: Double
    let elevationGainMeters: Double
    let speedMetersPerSecond: Double
    let segmentCount: Int

    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .bottomLeading) {
            if SimulatedRideConfig.current != nil {
                Text(RideTestProbe.line(distanceMeters: distanceMeters,
                                        elapsed: elapsed,
                                        elevationGainMeters: elevationGainMeters,
                                        speedMetersPerSecond: speedMetersPerSecond,
                                        segmentCount: segmentCount))
                    .font(.system(size: 8))
                    .opacity(0.02)   // invisible to riders, present in the a11y tree
                    .accessibilityIdentifier(RideTestID.hudProbe)
                    .allowsHitTesting(false)
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Attach the golden-ride probe. Safe to leave in the modifier chain
    /// unconditionally; it is a no-op outside DEBUG simulated rides.
    func simulatedRideProbe(distanceMeters: Double, elapsed: Double,
                            elevationGainMeters: Double,
                            speedMetersPerSecond: Double,
                            segmentCount: Int) -> some View {
        modifier(SimulatedRideProbe(distanceMeters: distanceMeters, elapsed: elapsed,
                                    elevationGainMeters: elevationGainMeters,
                                    speedMetersPerSecond: speedMetersPerSecond,
                                    segmentCount: segmentCount))
    }
}
