import SwiftUI
import AuraKit

/// Shown when the rider tries to start a ride without location permission. Explains why
/// and deep-links to Settings. Presented as a sheet from the HUDs.
struct LocationPermissionView: View {
    var onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xl) {
            Image(systemName: "location.slash")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(AuraTheme.accent)
            Text("Location needed to ride")
                .font(.title2.weight(.bold)).foregroundStyle(AuraTheme.textPrimary)
            Text("Aura records your route and follows you on the map. Turn on location access in Settings to start a ride.")
                .font(.subheadline).foregroundStyle(AuraTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { onOpenSettings() }
                .buttonStyle(.ctaPrimary)
            // .ctaTertiary is only 40pt tall — add vertical padding + a full-width
            // content shape so the "Not now" hit area clears the 44pt minimum.
            Button("Not now") { dismiss() }
                .buttonStyle(.ctaTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AuraTheme.Spacing.xs)
                .contentShape(Rectangle())
        }
        .padding(AuraTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuraTheme.background)
    }
}
