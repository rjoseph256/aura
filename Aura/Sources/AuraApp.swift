import SwiftUI
import SwiftData
import AuraCore
import AuraKit
import MapboxMaps

@main
struct AuraApp: App {
    @State private var router = AppRouter()
    @State private var rideStore = AuraApp.makeRideStore()
    @State private var settings = SettingsStore()
    @State private var location = LocationService()

    init() { AuraApp.configureMapbox() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(rideStore)
                .environment(settings)
                .environment(location)
                .preferredColorScheme(.dark)
        }
    }

    /// Builds the app's persistent SwiftData-backed RideStore. Falls back to an
    /// in-memory store if the on-disk container can't be created, so the app still runs.
    @MainActor static func makeRideStore() -> RideStore {
        do {
            return try RideStore.persistent()
        } catch {
            assertionFailure("Failed to build persistent ModelContainer: \(error)")
            return (try? RideStore.inMemory()) ?? {
                // Last-resort: an in-memory store should never fail; if it does, crash loudly.
                fatalError("Could not create any RideStore: \(error)")
            }()
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

}

// MARK: - RootView

/// Routes the window to the correct screen based on AppRouter.screen.
private struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            switch router.screen {
            case .plan:
                AuraTabView()

            case .preview(let destination):
                RoutePreviewView(destination: destination)

            case .ride(let route, let destination):
                if let route {
                    NavigateHUDView(route: route, destination: destination)
                } else {
                    // Free ride — unchanged path
                    RideHUDView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.screen)
    }
}

// MARK: - AuraTabView

/// Three-tab shell shown on the plan screen. History & Settings get their own
/// NavigationStacks (sheets / NavigationLinks need them); the Ride tab hosts the
/// router-driven plan→preview→ride flow's entry point (PlanView), which manages
/// its own layout and needs no nav bar.
private struct AuraTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            PlanView()
                .tabItem { Label("Ride", systemImage: "bicycle") }
                .tag(AppRouter.Tab.ride)

            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppRouter.Tab.history)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppRouter.Tab.settings)
        }
        .tint(AuraTheme.accent)
    }
}
