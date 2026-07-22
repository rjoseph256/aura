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
        #if DEBUG
        // Golden-ride harness (ROH-92): a fresh in-memory store per launch keeps the
        // History assertion deterministic across local runs and CI sims.
        if SimulatedRideConfig.currentForcesInMemoryStore, let store = try? RideStore.inMemory() {
            return store
        }
        #endif
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
    @Environment(LocationService.self) private var location
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
                    case let .rideSummary(payload):
                        // Pushed (not a sheet) so returning Home via popToRoot animates
                        // summary → Home with no HUD to flash (ROH-85). Chrome hidden + swipe
                        // back off so the summary is a terminal screen exited only via Done
                        // (with the path collapsed to one entry, a VoiceOver .escape also lands
                        // on Home). A foreground deep link while this is up replaces the path
                        // (isRideActive is false) — accepted, same as the old sheet.
                        RideSummaryView(ride: payload.ride, saveFailed: payload.saveFailed,
                                        onDone: { router.popToRoot() })
                            .toolbar(.hidden, for: .navigationBar)
                            .navigationBarBackButtonHidden(true)
                            .swipeBackEnabled(false)
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
            syncLocationActivity()
        }
        .onChange(of: router.path) { _, _ in syncLocationActivity() }
        .onChange(of: router.isRideActive) { _, _ in syncLocationActivity() }
        .onChange(of: location.authorization) { _, _ in syncLocationActivity() }
        .task { syncLocationActivity() }
        .onChange(of: router.pendingSignIn) { _, entry in
            guard entry != nil else { return }          // fires only on nil -> entry (gate's reentrancy guard blocks overwrite)
            Task {
                await auth.signInWithApple()
                // cancel or failure: drop the intent, stay put
                if auth.isSignedIn { router.resumePendingGroupRide() } else { router.cancelPendingGroupRide() }
            }
        }
    }

    /// Single writer for the non-ride location tier. Computes the desired tier from explicit
    /// app state (never from view appear/disappear, which is unreliable on this retained nav
    /// root) and applies it. The ride pipeline owns `.navigating` via the coordinator, so this
    /// yields entirely while a ride is active.
    ///
    /// `isHomeForeground` uses `scenePhase != .background` (NOT `== .active`): a transient
    /// `.inactive` — Control Center, a notification banner, a permission alert — must NOT tear
    /// down the ambient monitor. Ambient is released only on a real `.background`.
    private func syncLocationActivity() {
        #if DEBUG
        // Golden-ride harness: never engage the ambient CoreLocation tier while a ride is
        // simulated, so no permission prompt can interrupt the UI test mid-navigation.
        if SimulatedRideConfig.current != nil { return }
        #endif
        let isHomeForeground = router.path.isEmpty && scenePhase != .background
        switch LocationAccuracyMode.desired(isRideActive: router.isRideActive,
                                            isHomeForeground: isHomeForeground,
                                            authorized: location.authorization == .authorized) {
        case .ambient: location.startAmbient()
        case .idle: location.releaseNonRide()
        case .navigating: break   // owned by the ride pipeline
        }
    }
}
