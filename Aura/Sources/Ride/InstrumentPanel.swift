import SwiftUI
import AuraCore
import AuraKit

/// The navigate cockpit's instrument panel: a hero SPEED readout beside the distance still
/// to go and the arrival ETA, on the shared `InstrumentChassis`. Driven by the live current
/// speed and the pure `CruisingState`, so it previews without any guidance engine.
struct InstrumentPanel: View {
    /// Smoothed live current speed (m/s) — the hero reads this, not the ride average.
    let currentSpeedMetersPerSecond: Double
    let units: DistanceUnits
    let trip: CruisingState

    var body: some View {
        InstrumentChassis(
            currentSpeedMetersPerSecond: currentSpeedMetersPerSecond,
            units: units,
            topLine: trip.streetName,
            columnAccessibilityLabel: trip.accessibilityLabel) {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                CockpitInstrument(value: trip.distanceRemaining ?? "–", label: "TO GO")
                CockpitInstrument(value: trip.eta ?? "–", label: "ARRIVE")
            }
        }
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        AuraTheme.background.ignoresSafeArea()
        InstrumentPanel(
            currentSpeedMetersPerSecond: 8.1, // ~18 mph
            units: .imperial,
            trip: .init(streetName: "Stedman Street", distanceRemaining: "7.2 mi",
                        eta: "11:32 PM",
                        accessibilityLabel: "On Stedman Street, 7.2 miles to go, arriving 11:32 PM"))
            .containerRelativeFrame(.vertical, count: 4, span: 1, spacing: 0)
    }
}
