import SwiftUI
import AuraKit

struct SettingsView: View {
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(AuthStore.self) private var auth
    @Environment(AppRouter.self) private var router
    @State private var displayNameStore = DisplayNameStore(backend: SupabaseGroupRideBackend())
    @State private var confirmingDelete = false

    var body: some View {
        // Bind controls straight to the observable store — each change persists via the
        // store's didSet, and any view reading these settings re-renders reactively.
        @Bindable var settings = settings

        return List {
            Section("Account") {
                if auth.isSignedIn {
                    NavigationLink {
                        DisplayNameEditor(store: displayNameStore, dismissesOnSave: true)
                    } label: {
                        linkLabel(icon: "person.crop.circle.fill", tint: AuraTheme.accent,
                                  title: "Crew name", value: displayNameStore.name)
                    }
                    Button { Task { await auth.signOut() } } label: {
                        actionLabel(icon: "rectangle.portrait.and.arrow.right",
                                    tint: AuraTheme.textSecondary, title: "Sign out")
                    }
                    .disabled(router.isRideActive)
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        actionLabel(icon: "trash", tint: AuraTheme.destructive, title: "Delete account")
                    }
                    .disabled(router.isRideActive)
                } else {
                    // The app owns the Apple token flow (AppleSignInController), so a native
                    // SignInWithAppleButton would fire its OWN competing request. Render a
                    // themed button that calls auth.signInWithApple() directly instead.
                    Button {
                        Task { await auth.signInWithApple() }
                    } label: {
                        Label("Sign in with Apple", systemImage: "apple.logo")
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    Text("Sign in to ride with your crew.")
                        .font(.footnote).foregroundStyle(AuraTheme.textSecondary)
                }
            }
            .listRowBackground(AuraTheme.surface)
            .alert("Delete account?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { Task { await auth.deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your crew profile and any group-ride data on the server. " +
                     "Your ride history on this device is not affected.")
            }

            Section("Ride") {
                row(icon: "ruler", tint: AuraTheme.accent, title: "Distance units") {
                    Picker("", selection: $settings.units) {
                        Text("Miles").tag(DistanceUnits.imperial)
                        Text("Kilometers").tag(DistanceUnits.metric)
                    }
                    .labelsHidden().pickerStyle(.menu).tint(AuraTheme.accent)
                }
                row(icon: "speaker.wave.2.fill", tint: AuraTheme.accent, title: "Voice guidance") {
                    Toggle("", isOn: $settings.voiceEnabled)
                        .labelsHidden().tint(AuraTheme.accent)
                }
                row(icon: "hand.tap.fill", tint: AuraTheme.accent, title: "Turn haptics") {
                    Toggle("", isOn: $settings.turnHaptics)
                        .labelsHidden().tint(AuraTheme.accent)
                        .accessibilityIdentifier("settings.turnHaptics")
                }
                HealthAccessRow()
                PauseRemindersRow()
                row(icon: "target", tint: AuraTheme.accent, title: "Weekly goal") {
                    Stepper(value: goalBinding(settings), in: 5...200, step: 5) {
                        Text(goalLabel(settings))
                            .foregroundStyle(AuraTheme.textSecondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("settings.weeklyGoalValue")
                    }
                    .fixedSize()
                }
            }
            .listRowBackground(AuraTheme.surface)

            Section("Map") {
                row(icon: "map.fill", tint: AuraTheme.accent, title: "Map style") {
                    Picker("", selection: $settings.mapStyle) {
                        Text("Terrain (Aura)").tag(MapStyle.auraTerrain)
                        Text("Dark").tag(MapStyle.dark)
                        Text("Standard").tag(MapStyle.standard)
                    }
                    .labelsHidden().pickerStyle(.menu).tint(AuraTheme.accent)
                }
                NavigationLink {
                    OfflineMapsView()
                } label: {
                    linkLabel(icon: "arrow.down.circle.fill", tint: AuraTheme.accent, title: "Offline maps")
                }
            }
            .listRowBackground(AuraTheme.surface)

            Section("About") {
                NavigationLink {
                    AttributionView()
                } label: {
                    linkLabel(icon: "info.circle.fill", tint: AuraTheme.textSecondary, title: "Attribution & data")
                }
            }
            .listRowBackground(AuraTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(AuraTheme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        // Settings is only reachable by pushing from Home's control cluster or the first-run
        // CTA, and Home is buried beneath whatever ride HUD is on the shared NavigationStack
        // while a ride records; the aura://settings deep link is also dropped while
        // router.isRideActive. So this screen cannot be on screen with a ride in flight, and
        // activeRideID is always nil here — investigated for ROH-107 Task 4, not assumed.
        // (The `.disabled(router.isRideActive)` guards above on sign-out/delete-account are
        // therefore currently unreachable too; left alone rather than removed in this commit.)
        .onChange(of: settings.weeklyGoalMeters) { _, _ in
            WidgetRefresh.reload(rideStore: rideStore, settings: settings, activeRideID: nil)
        }
        .onChange(of: settings.units) { _, _ in
            WidgetRefresh.reload(rideStore: rideStore, settings: settings, activeRideID: nil)
        }
    }

    // A settings row: colored icon badge + title + trailing control.
    private func row<Control: View>(icon: String, tint: Color, title: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            iconView(icon, tint)
            Text(title).foregroundStyle(AuraTheme.textPrimary)
            Spacer()
            control()
        }
    }

    private func linkLabel(icon name: String, tint: Color, title: String,
                           value: String? = nil) -> some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            iconView(name, tint)
            Text(title).foregroundStyle(AuraTheme.textPrimary)
            if let value, !value.isEmpty {
                Spacer(minLength: AuraTheme.Spacing.sm)
                Text(value)
                    .foregroundStyle(AuraTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // A tappable row's label: colored icon badge + title, with the title left to inherit
    // the button's own color (accent, or destructive red) rather than being forced primary.
    private func actionLabel(icon name: String, tint: Color, title: String) -> some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            iconView(name, tint)
            Text(title)
        }
    }

    private func iconView(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 26)
    }

    // MARK: - Weekly goal (stored in meters; edited in the rider's chosen unit)

    /// Bridges the meters-backed goal to a whole-unit value the stepper edits in
    /// 5 mi / 5 km steps. `get` rounds so the stepper always lands on round numbers.
    private func goalBinding(_ s: SettingsStore) -> Binding<Double> {
        Binding(
            get: { (s.units == .metric ? s.weeklyGoalMeters / 1000 : s.weeklyGoalMeters / 1609.344).rounded() },
            set: { s.weeklyGoalMeters = $0 * (s.units == .metric ? 1000 : 1609.344) }
        )
    }

    private func goalLabel(_ s: SettingsStore) -> String {
        let v = (s.units == .metric ? s.weeklyGoalMeters / 1000 : s.weeklyGoalMeters / 1609.344).rounded()
        return "\(Int(v)) \(s.units == .metric ? "km" : "mi")"
    }
}
