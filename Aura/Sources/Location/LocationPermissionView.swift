import SwiftUI
import AuraKit

/// Shown when the rider tries to start a ride without location permission. Explains why
/// and deep-links to Settings. Presented as a sheet from the HUDs.
struct LocationPermissionView: View {
    var onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.slash")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(AuraTheme.cyan)
            Text("Location needed to ride")
                .font(.title2.weight(.bold)).foregroundStyle(AuraTheme.text)
            Text("Aura records your route and follows you on the map. Turn on location access in Settings to start a ride.")
                .font(.subheadline).foregroundStyle(AuraTheme.muted)
                .multilineTextAlignment(.center)
            Button("Open Settings") { onOpenSettings() }
                .font(.headline).foregroundStyle(.black)
                .padding(.vertical, 14).frame(maxWidth: .infinity)
                .background(AuraTheme.auroraGradient, in: Capsule())
            Button("Not now") { dismiss() }
                .font(.subheadline).foregroundStyle(AuraTheme.muted)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuraTheme.bg)
    }
}
