import SwiftUI
import WeatherKit

struct AttributionView: View {
    @Environment(\.colorScheme) private var colorScheme
    // Apple requires attribution wherever WeatherKit data appears. Fetched lazily; the section
    // only shows once attribution loads (which requires the WeatherKit capability), matching the
    // state in which weather actually appears in the app.
    @State private var weatherAttribution: WeatherAttribution?

    var body: some View {
        List {
            Section("Map data") {
                Link("© OpenStreetMap contributors",
                     destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Text("Map data is available under the Open Database License (ODbL).")
                    .font(.caption).foregroundStyle(AuraTheme.textSecondary)
            }
            Section("Pittsburgh bike data") {
                Link("BikePGH / WPRDC (CC-BY)",
                     destination: URL(string: "https://data.wprdc.org/dataset/shape-files-for-bikepgh-s-pittsburgh-bike-map")!)
            }
            Section("Maps & navigation") { Text("© Mapbox") }
            if let weatherAttribution {
                Section("Weather") {
                    if let markURL {
                        AsyncImage(url: markURL) { image in
                            image.resizable().scaledToFit().frame(height: 16)
                        } placeholder: { EmptyView() }
                        .accessibilityLabel("Apple Weather")
                    }
                    Link("Weather data sources", destination: weatherAttribution.legalPageURL)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuraTheme.background.ignoresSafeArea())
        .tint(AuraTheme.accent)
        .navigationTitle("Attribution & data")
        .task { weatherAttribution = try? await WeatherService.shared.attribution }
    }

    private var markURL: URL? {
        guard let a = weatherAttribution else { return nil }
        return colorScheme == .dark ? a.combinedMarkDarkURL : a.combinedMarkLightURL
    }
}
