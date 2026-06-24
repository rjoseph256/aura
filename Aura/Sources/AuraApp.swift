import SwiftUI
import AuraCore
import AuraKit
import MapboxMaps

@main
struct AuraApp: App {
    @State private var router = AppRouter()

    init() { AuraApp.configureMapbox() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
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

// MARK: - RootView

/// Routes the window to the correct screen based on AppRouter.screen.
private struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            switch router.screen {
            case .plan:
                PlanView()

            case .preview(let destination):
                RoutePreviewView(destination: destination)

            case .ride(let route):
                if let route {
                    NavigateHUDView(route: route)
                } else {
                    // Free ride — unchanged path
                    RideHUDView(makeProvider: { LiveLocationProvider() })
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.screen)
    }
}

