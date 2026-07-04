import SwiftUI
import AuraCore
import AuraKit

/// The Explore (free-ride) cockpit's instrument panel: a hero SPEED readout beside distance
/// ridden, elapsed time, and elevation climbed, on the shared `InstrumentChassis`. Driven by
/// the live current speed and the pure `ExploreInstrumentState` — no destination, no ETA, no
/// street — so it previews without a running ride.
struct ExploreInstrumentPanel: View {
    /// Smoothed live current speed (m/s) — the hero reads this, not the ride average.
    let currentSpeedMetersPerSecond: Double
    let units: DistanceUnits
    let state: ExploreInstrumentState

    var body: some View {
        InstrumentChassis(
            currentSpeedMetersPerSecond: currentSpeedMetersPerSecond,
            units: units,
            topLine: nil,
            columnAccessibilityLabel: state.accessibilityLabel) {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                CockpitInstrument(value: state.distance, label: "DISTANCE")
                CockpitInstrument(value: state.time, label: "TIME")
                CockpitInstrument(value: state.elevationGain, label: "CLIMB")
            }
        }
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        AuraTheme.background.ignoresSafeArea()
        ExploreInstrumentPanel(
            currentSpeedMetersPerSecond: 8.1,
            units: .imperial,
            state: ExploreInstrumentState(
                stats: RideStats(distanceMeters: 8046.72, movingTimeSeconds: 1440,
                                 averageSpeedMetersPerSecond: 5.6, maxSpeedMetersPerSecond: 9,
                                 elevationGainMeters: 103.6),
                elapsed: 1440, units: .imperial))
            .containerRelativeFrame(.vertical, count: 4, span: 1, spacing: 0)
    }
}
