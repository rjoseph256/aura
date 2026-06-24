import SwiftUI
import AuraKit

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        // Bind controls straight to the observable store — each change persists via the
        // store's didSet, and any view reading these settings re-renders reactively.
        @Bindable var settings = settings

        return List {
            Section("Ride") {
                row(icon: "ruler", tint: AuraTheme.cyan, title: "Distance units") {
                    Picker("", selection: $settings.units) {
                        Text("Miles").tag(DistanceUnits.imperial)
                        Text("Kilometers").tag(DistanceUnits.metric)
                    }
                    .labelsHidden().pickerStyle(.menu).tint(AuraTheme.cyan)
                }
                row(icon: "speaker.wave.2.fill", tint: AuraTheme.route, title: "Voice guidance") {
                    Toggle("", isOn: $settings.voiceEnabled)
                        .labelsHidden().tint(AuraTheme.route)
                }
            }
            .listRowBackground(AuraTheme.surface)

            Section("Map") {
                row(icon: "map.fill", tint: AuraTheme.violet, title: "Map style") {
                    Picker("", selection: $settings.mapStyle) {
                        Text("Dark").tag(MapStyle.dark)
                        Text("Standard").tag(MapStyle.standard)
                    }
                    .labelsHidden().pickerStyle(.menu).tint(AuraTheme.cyan)
                }
                NavigationLink {
                    OfflineMapsView()
                } label: {
                    linkLabel(icon: "arrow.down.circle.fill", tint: AuraTheme.cyan, title: "Offline maps")
                }
            }
            .listRowBackground(AuraTheme.surface)

            Section("About") {
                NavigationLink {
                    AttributionView()
                } label: {
                    linkLabel(icon: "info.circle.fill", tint: AuraTheme.muted, title: "Attribution & data")
                }
            }
            .listRowBackground(AuraTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(AuraTheme.bg.ignoresSafeArea())
        .navigationTitle("Settings")
    }

    // A settings row: colored icon badge + title + trailing control.
    private func row<Control: View>(icon: String, tint: Color, title: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            iconView(icon, tint)
            Text(title).foregroundStyle(AuraTheme.text)
            Spacer()
            control()
        }
    }

    private func linkLabel(icon name: String, tint: Color, title: String) -> some View {
        HStack(spacing: 12) {
            iconView(name, tint)
            Text(title).foregroundStyle(AuraTheme.text)
        }
    }

    private func iconView(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26)
    }
}
