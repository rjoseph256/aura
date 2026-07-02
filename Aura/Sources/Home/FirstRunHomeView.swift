import SwiftUI
import AuraCore
import AuraKit

/// First-run Home: a purpose-framed location ask over a curated sample terrain, and one
/// unmistakable primary. Its own composition, not the populated layout with empty strings.
/// Tapping the primary marks onboarding complete and routes into planning (the location
/// prompt is triggered by the app's existing entry point, not a competing second CTA).
struct FirstRunHomeView: View {
    let renderer: TerrainSnapshotRendering
    let onStart: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            HomeBackdrop(renderer: renderer, riderCoordinate: nil, placeName: "Pittsburgh")

            VStack(spacing: AuraTheme.Spacing.md) {
                Text("Aura needs your location to map your hills")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AuraTheme.textPrimary)
                Text("Sample terrain shown — your first ride maps your own.")
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Plan your first ride", action: onStart)
                    .buttonStyle(.ctaPrimary)
                    .accessibilityIdentifier("home.planFirstRide")
                    .padding(.top, AuraTheme.Spacing.sm)
            }
            .padding(.horizontal, AuraTheme.Spacing.xxl)
            .padding(.bottom, AuraTheme.Spacing.xxl)
        }
    }
}
