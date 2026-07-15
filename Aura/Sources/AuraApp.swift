import SwiftUI
import AuraCore
import AuraKit
import MapboxMaps

@main
struct AuraApp: App {
    @State private var router: AppRouter
    @State private var auth: AuthStore
    @State private var rideStore: RideStore
    @State private var savedPlaces: SavedPlacesStore
    @State private var settings = SettingsStore(defaults: .standard, sync: UbiquitousKeyValueStore())
    @State private var location = LocationService()
    @State private var weather = WeatherStore(provider: WeatherKitProvider())

    init() {
        AuraApp.configureMapbox()
        let store = AuraApp.makeRideStore()
        _rideStore = State(initialValue: store)
        _savedPlaces = State(initialValue: SavedPlacesStore(container: store.container))

        let authStore = AuthStore(backend: SupabaseGroupRideBackend(), apple: AppleSignInController())
        let appRouter = AppRouter()
        appRouter.checkSignedIn = { [weak authStore] in authStore?.isSignedIn ?? false }
        _auth = State(initialValue: authStore)
        _router = State(initialValue: appRouter)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(auth)
                .environment(rideStore)
                .environment(savedPlaces)
                .environment(settings)
                .environment(location)
                .environment(weather)
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

/// The app's single navigation stack, rooted at Home, whose path the AppRouter owns. There
/// is no tab bar: History and Settings are pushed routes reached from the Home control
/// cluster (an always-present dashboard sheet would otherwise bury a bottom tab bar). Pushing
/// preview or a ride HUD retains the screen beneath it, so transitions no longer tear down
/// and rebuild the Mapbox map.
private struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AuthStore.self) private var auth
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
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
                    case .joinRide:
                        // Pushed (not a sheet) so it never conflicts with Home's
                        // always-present dashboard sheet; only the view's own Cancel shows.
                        GroupRideJoinView()
                            .navigationBarBackButtonHidden(true)
                    case .history:
                        HistoryView()
                    case .settings:
                        SettingsView()
                    }
                }
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
        .onChange(of: router.pendingSignIn) { _, entry in
            guard entry != nil else { return }          // fires only on nil -> entry (gate's reentrancy guard blocks overwrite)
            Task {
                await auth.signInWithApple()
                // cancel or failure: drop the intent, stay put
                if auth.isSignedIn { router.resumePendingGroupRide() } else { router.cancelPendingGroupRide() }
            }
        }
    }
}
