import SwiftUI
import AuraKit

struct SettingsView: View {
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        // Bind controls straight to the observable store — each change persists via the
        // store's didSet, and any view reading these settings re-renders reactively.
        @Bindable var settings = settings

        return List {
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
                }
                HealthAccessRow()
                row(icon: "target", tint: AuraTheme.accent, title: "Weekly goal") {
                    Stepper(value: goalBinding(settings), in: 5...200, step: 5) {
                        Text(goalLabel(settings))
                            .foregroundStyle(AuraTheme.textSecondary)
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
            }
            .listRowBackground(AuraTheme.surface)

            Section("Map") {
                row(icon: "map.fill", tint: AuraTheme.accent, title: "Map style") {
                    Picker("", selection: $settings.mapStyle) {
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
        .onChange(of: settings.weeklyGoalMeters) { _, _ in
            WidgetRefresh.reload(rideStore: rideStore, settings: settings)
        }
        .onChange(of: settings.units) { _, _ in
            WidgetRefresh.reload(rideStore: rideStore, settings: settings)
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

    private func linkLabel(icon name: String, tint: Color, title: String) -> some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            iconView(name, tint)
            Text(title).foregroundStyle(AuraTheme.textPrimary)
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
