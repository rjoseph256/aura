import SwiftUI

struct AttributionView: View {
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
        }
        .scrollContentBackground(.hidden)
        .background(AuraTheme.background.ignoresSafeArea())
        .tint(AuraTheme.accent)
        .navigationTitle("Attribution & data")
    }
}
