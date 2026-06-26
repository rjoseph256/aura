import SwiftUI
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
                .onOpenURL { router.handle(url: $0) }
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

/// The app's tab shell. The Ride tab is a NavigationStack whose path the AppRouter owns;
/// History and Settings keep their own stacks. Pushing preview or a ride HUD retains the
/// screen beneath it, so transitions no longer tear down and rebuild the Mapbox map.
private struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.path) {
                PlanView()
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .freeRide:
                            RideHUDView()
                        case let .preview(place):
                            RoutePreviewView(destination: place)
                        case let .navigate(route, destination):
                            NavigateHUDView(route: route, destination: destination)
                        }
                    }
            }
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
