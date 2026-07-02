import SwiftUI
import AuraCore
import AuraKit
import MapboxMaps

@main
struct AuraApp: App {
    @State private var router = AppRouter()
    @State private var rideStore: RideStore
    @State private var savedPlaces: SavedPlacesStore
    @State private var settings = SettingsStore(defaults: .standard, sync: UbiquitousKeyValueStore())
    @State private var location = LocationService()

    init() {
        AuraApp.configureMapbox()
        let store = AuraApp.makeRideStore()
        _rideStore = State(initialValue: store)
        _savedPlaces = State(initialValue: SavedPlacesStore(container: store.container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(rideStore)
                .environment(savedPlaces)
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
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .freeRide:
                            RideHUDView()
                        case let .preview(place):
                            RoutePreviewView(destination: place)
                        case let .navigate(route, destination):
                            NavigateHUDView(route: route, destination: destination)
                        case let .groupRide(entry):
                            GroupRideFlowView(entry: entry)
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
        .task { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        // UI-test support: "-openURL <url>" routes through the normal deep-link path
        // on first appearance. Inert in production (no argument, no effect).
        .task {
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-openURL"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1),
               let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]) {
                router.handle(url: url)
            }
        }
        // Consumed exactly once for the app's lifetime (the underlying AsyncStream is single-consumer).
        .task {
            for await change in settings.kvSyncStream {
                let changed = settings.applyRemoteChange(change)
                if changed.contains("units") || changed.contains("weeklyGoalMeters") {
                    WidgetRefresh.reload(rideStore: rideStore, settings: settings)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        }
    }
}
