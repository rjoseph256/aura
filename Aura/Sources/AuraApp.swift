import SwiftUI
import AuraCore
import AuraKit
import MapboxMaps

@main
struct AuraApp: App {
    init() { AuraApp.configureMapbox() }

    var body: some Scene {
        WindowGroup {
            // Real GPS by default. For a desk demo without moving, swap to: Self.simulatedProvider
            RideHUDView(makeProvider: { LiveLocationProvider() })
        }
    }

    /// Reads the untracked bundled token file and configures Mapbox. See .mapbox-setup.md.
    static func configureMapbox() {
        guard let url = Bundle.main.url(forResource: "MapboxAccessToken", withExtension: nil),
              let token = try? String(contentsOf: url, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            assertionFailure("Missing Mapbox token — see .mapbox-setup.md")
            return
        }
        MapboxOptions.accessToken = token
    }

    /// Loads the bundled GPX and replays it at 10× for a quick desk demo.
    static func simulatedProvider() -> LocationStreaming {
        guard let url = Bundle.main.url(forResource: "sample-ride-pittsburgh", withExtension: "gpx"),
              let xml = try? String(contentsOf: url, encoding: .utf8),
              let track = try? GPXParser.parse(xml) else {
            return SimulatedLocationProvider(track: GPXTrack(points: []))
        }
        return SimulatedLocationProvider(track: track, speedMultiplier: 10)
    }
}
