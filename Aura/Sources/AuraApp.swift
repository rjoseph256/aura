import SwiftUI
import AuraCore
import AuraKit
import MapboxMaps

@main
struct AuraApp: App {
    @UIApplicationDelegateAdaptor(AuraAppDelegate.self) private var appDelegate
    @State private var router: AppRouter
    @State private var auth: AuthStore
    @State private var rideStore: RideStore
    @State private var savedPlaces: SavedPlacesStore
    @State private var settings = SettingsStore(defaults: .standard, sync: UbiquitousKeyValueStore())
    @State private var location = LocationService()
    @State private var weather = WeatherStore(provider: WeatherKitProvider())
    /// The app's ONE share-map provider: the single-flight dedup table lives on the
    /// instance, so the ride-end prefetch and the summary's own request must share it.
    @State private var shareMapBox = ShareMapProviderBox(provider: ShareMapSnapshotter.shared)

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
                .environment(shareMapBox)
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
    /// The V6 segment backfill sweep (ROH-100). Held so a starting ride can cancel it, and so
    /// a second `.task` invocation (a scene reconnect) does not start a second sweep.
    @State private var backfill: Task<RideSegmentBackfill.Result, Never>?

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
                    case let .joinRide(seed):
                        // Pushed (not a sheet) so it never conflicts with Home's
                        // always-present dashboard sheet; only the view's own Cancel shows.
                        GroupRideJoinView(seed: seed)
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
        // Launch .task; no ride can be active yet.
        .task { WidgetRefresh.reload(rideStore: rideStore, settings: settings, activeRideID: nil) }
        // Ghost Live Activities a killed process left behind (ROH-124).
        //
        // Its own `.task`, not the backfill one below. That closure is synchronous end to end, and
        // its `guard backfill == nil` check-then-set is idempotent on a scene reconnect only
        // because nothing between the read and the write can yield. An `await` added there would
        // let two invocations both observe nil and spawn two concurrent 50-row backfill sweeps on
        // one ModelContainer.
        //
        // Unguarded by ride state on purpose: `endOrphans()` excludes the activity it owns, and
        // `router.activeRideID` lags `coordinator.isRecording` by an update cycle, so it is nil
        // during a window in which a ride is already recording and owns an activity.
        //
        // Swept twice: once now, once after a short delay. ActivityKit restores this process's
        // view of existing activities asynchronously after launch, and a read taken on the first
        // frame can come back empty — most likely on a phone under the same memory pressure that
        // caused the kill. Without the second pass the ghost would survive until the rider next
        // backgrounds and returns, or starts a ride.
        .task {
            #if DEBUG
            guard !SimulatedRideConfig.currentSuppressesLaunchOrphanSweep else { return }
            #endif
            RideLiveActivityController.shared.endOrphans()
            try? await Task.sleep(for: .seconds(2))
            RideLiveActivityController.shared.endOrphans()
        }
        // Schema V6's segment backfill (ROH-100). Deliberately not in the V5→V6 migration
        // stage: stages run inside `ModelContainer.init`, which `AuraApp.init()` calls before
        // the first frame, so re-encoding a long ride history there is a watchdog kill that
        // repeats on every launch.
        //
        // **`Task.detached` is load-bearing.** `RideSegmentBackfill.run` is synchronous and does
        // its work on the calling thread with a `ModelContext` it owns, so a plain `Task { }`
        // here would inherit this view's MainActor isolation and run the whole sweep on the main
        // thread — one frame later than the migration stage it was moved out of. Detached also
        // keeps `.utility` from being escalated by an awaiting caller.
        //
        // Budgeted at 50 rows per launch because every filled row is a CloudKit export: a long
        // history spreads over several launches instead of one upload burst. Un-filled rows
        // read correctly meanwhile — the mapper wraps their flat track.
        //
        // Skipped for an ephemeral store, which has nothing to backfill and does not survive
        // the launch, and cancelled when a ride starts: the sweep is resumable, and the rider's
        // ride owns the device from that moment.
        .task {
            // Clear any pause nudge an earlier process orphaned. A jetsam kill during a pause,
            // which is the likely end of a long stop, leaves the ladder scheduled with nobody
            // left to cancel it.
            //
            // Safe **only** because a persisted checkpoint is never resumable: a pause writes a
            // real row (ROH-107's badge is for exactly that row), so "nothing persists an
            // in-flight ride" is false — what is true is that nothing restores one. If
            // checkpoint restore ever lands, this becomes "destroy the nudges for the ride we
            // just restored" and must move behind that check.
            //
            // Idempotent, which matters: this `.task` re-runs on a scene reconnect, the same
            // hazard the V6 backfill sweep below had to be guarded against.
            if router.activeRideID == nil {
                PauseNudgeScheduler.shared.cancelForgottenPauseNudges()
            }
            guard !rideStore.isEphemeral, backfill == nil else { return }
            let container = rideStore.container
            backfill = Task.detached(priority: .utility) {
                RideSegmentBackfill.run(container: container, maxRows: 50)
            }
        }
        .onChange(of: router.isRideActive) { _, active in
            if active { backfill?.cancel() }
        }
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
                    // KVS sync loop — reachable mid-ride when another device changes a setting.
                    WidgetRefresh.reload(rideStore: rideStore, settings: settings,
                                         activeRideID: router.activeRideID)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // The scenePhase edge, which is the leak this fixes.
            if phase == .active {
                WidgetRefresh.reload(rideStore: rideStore, settings: settings,
                                     activeRideID: router.activeRideID)
                // A session that launched before ActivityKit had restored its activity list, or
                // whose first request threw, would otherwise carry the ghost for the life of the
                // process (ROH-124). A no-op mid-ride: the running activity is the owned one.
                #if DEBUG
                let suppressed = SimulatedRideConfig.currentSuppressesOrphanSweep
                #else
                let suppressed = false
                #endif
                if !suppressed { RideLiveActivityController.shared.endOrphans() }
            }
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
