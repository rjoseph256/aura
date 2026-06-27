import SwiftUI
import AuraKit

/// The "Save rides to Health" Settings row. Owns the HealthKit authorization
/// interaction so `SettingsView` stays declarative and `AuraKit` stays HealthKit-free.
/// Turning the toggle on requests write authorization; a denial or an unavailable
/// store reverts the toggle and explains why, so the control never lies about whether
/// rides will actually save.
struct HealthAccessRow: View {
    @Environment(SettingsStore.self) private var settings
    @State private var showDenied = false
    @State private var showUnavailable = false

    var body: some View {
        @Bindable var settings = settings
        HStack(spacing: AuraTheme.Spacing.md) {
            Image(systemName: "heart.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.accent)
                .frame(width: 26)
            Text("Save rides to Health").foregroundStyle(AuraTheme.textPrimary)
            Spacer()
            Toggle("", isOn: $settings.saveToHealth)
                .labelsHidden().tint(AuraTheme.accent)
                .accessibilityLabel("Save rides to Health")
        }
        .onChange(of: settings.saveToHealth) { _, isOn in
            guard isOn else { return }
            Task {
                switch await WorkoutWriter.shared.requestAuthorization() {
                case .authorized: break
                case .denied: settings.saveToHealth = false; showDenied = true
                case .unavailable: settings.saveToHealth = false; showUnavailable = true
                }
            }
        }
        .alert("Couldn't turn on Health", isPresented: $showDenied) {
            Button("Open Health") { HealthAppLink.open() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Aura doesn't have permission to save rides to Health. "
                 + "You can turn it on in the Health app under Sharing.")
        }
        .alert("Health unavailable", isPresented: $showUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device can't save rides to Health.")
        }
    }
}
