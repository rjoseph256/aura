import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// The Explore (free-ride) cockpit. Auto-starts recording on appear (parity with navigate),
/// shows the quarter-screen `ExploreInstrumentPanel` + a recenter/end `ControlCluster` over
/// the terrain map, and offers an always-visible back-out: a just-started ride (below the
/// discard floor) is discarded with no summary; once it is worth a summary, back opens the
/// End confirmation. Ending routes through the coordinator's finish → summary sheet.
struct RideHUDView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var coordinator: RideSessionCoordinator
    /// Orchestrates the "Take me there" detour (Plan 3): routing, turn-by-turn/offline
    /// heading fallback, and arrival. Owned here (not the coordinator) so the HUD can host
    /// `DetourOverlay` and feed `RideMapView`'s `detourRoute`; the coordinator holds it only
    /// as a `GuidanceControlling` seam for `riderDidUpdate`/`detach`.
    @State private var guidance: GuidanceController
    @State private var showPermission: Bool
    @State private var showEndConfirm: Bool
    @State private var viewport: Viewport
    // Free rides are solo by construction — group rides use NavigateHUDView +
    // GroupRideSession, never this HUD — so gem discovery is never suppressed here.
    // (GemDiscoveryStore.isSuppressed exists for a future group-explore surface.)
    // Built lazily in the appear .task: it needs SeenGemStore(container:) from `rideStore`,
    // which a @State initializer can't read.
    @State private var gems: GemDiscoveryStore?

    /// Builds the detour `GuidanceController` from app concretes and injects it into a fresh
    /// coordinator. `settings.units` isn't reachable here (SwiftUI environment values aren't
    /// resolved during a view's synchronous `init`), so `guidance` starts at the `.imperial`
    /// default; the live rider units still reach every on-screen distance text because
    /// `DetourOverlay` takes `units:` as a plain parameter from `settings` in `body`. Only the
    /// in-flight turn card's own formatting (sourced from `GuidanceViewModel.turn`, set once
    /// per leg in `GuidanceController.startGuidance`) would miss a metric rider's setting —
    /// a narrow, tracked gap; see Task 9 report.
    init() {
        let controller = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: MapboxGuidanceSession()) },
            routing: MapboxDetourRouting(), heading: CompassHeadingProvider())
        _guidance = State(initialValue: controller)
        _coordinator = State(initialValue: RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
            workout: WorkoutWriter.shared, guidance: controller))
        _showPermission = State(initialValue: false)
        _showEndConfirm = State(initialValue: false)
        _viewport = State(initialValue: .followPuck(zoom: 16, bearing: .heading))
        _gems = State(initialValue: nil)
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        ZStack(alignment: .bottom) {
            RideMapView(track: coordinator.track,
                        gems: gems?.visiblePins ?? [],
                        seenGemIDs: gems?.seenIDs ?? [],
                        onSelectGem: { gem in gems?.select(gem) },
                        detourRoute: guidance.activeRoute?.geometry ?? [],
                        viewport: $viewport)
            bottomCockpit
        }
        // Always-visible back-out: discards a just-started ride (below the floor) or opens
        // the End confirmation once the ride is long enough to be worth a summary. The label
        // announces which, so the change of meaning isn't silent.
        .overlay(alignment: .topLeading) {
            backButton
                .padding(.top, 8)
                .padding(.leading, 16)
        }
        // GPS signal chip — top-trailing so it doesn't collide with the back button.
        .overlay(alignment: .topTrailing) {
            GPSSignalChip(signal: location.signal)
                .padding(.top, 8).padding(.trailing, 16)
        }
        // The active layer: at most one self-dismissing peek card for a newly surfaced gem.
        // Sits up top, just below the back button, so it never covers the speedometer cluster.
        .overlay(alignment: .top) {
            if let store = gems, let gem = store.activeCard {
                GemPeekCard(gem: gem, distanceText: gemDistanceText(gem),
                            onTap: { store.select(gem); store.dismissActiveCard() },
                            onDismiss: { store.dismissActiveCard() })
                    .padding(.horizontal, 12).padding(.top, 60)
            }
        }
        .animation(.snappy, value: gems?.activeCard?.id)
        // The detour chrome (turn card / heading pointer / routing / arrival chip). Declared
        // AFTER the peek-card overlay above so it wins z-order if the two ever coexist — in
        // practice they don't, because the store arbiter (below) suppresses the peek card
        // while a detour is active.
        .overlay(alignment: .top) {
            if guidance.isDetouring || guidance.arrivalBanner != nil {
                DetourOverlay(controller: guidance, units: settings.units,
                              reduceMotion: reduceMotion, onStop: { guidance.cancel() })
                    .padding(.top, 8)
            }
        }
        .background(AuraTheme.background)
        .alert("End ride?", isPresented: $showEndConfirm) {
            Button("End ride", role: .destructive) { coordinator.finish() }
            Button("Keep riding", role: .cancel) { }
        }
        // Returning from the summary drops to the home dashboard, mirroring NavigateHUDView.
        .sheet(item: $coordinator.finishedRide, onDismiss: { router.popToRoot() }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
        .sheet(isPresented: $showPermission) {
            LocationPermissionView(onOpenSettings: RideSettingsLink.open)
        }
        .sheet(item: Binding(get: { gems?.selectedGem },
                             set: { gems?.selectedGem = $0 })) { gem in
            GemDetailSheet(
                gem: gem,
                distanceText: gemDistanceText(gem),
                canRoute: gems?.riderCoordinate != nil,
                onTakeMeThere: {
                    guard let origin = gems?.riderCoordinate else { return }
                    gems?.selectedGem = nil                    // dismiss the sheet
                    guidance.requestDetour(gem, from: origin)  // R6
                })
        }
        // Auto-start recording on appear (parity with navigate). A denied permission surfaces
        // the explainer; the back button (at zero distance) discards cleanly.
        .task {
            let store = gems ?? GemDiscoveryStore(
                provider: CuratedGemProvider(),
                seen: SeenGemStore(container: rideStore.container),
                haptics: GemHapticPlayer())
            // Arbiter (R7): a detour in flight suppresses the gem peek card + Tier-3 haptic
            // (turn cues own the cockpit) but pins/seen-state are unaffected.
            store.detourActive = { [coordinator] in coordinator.isDetouring }
            guidance.units = settings.units
            gems = store
            let outcome = coordinator.start(
                location: location, saving: rideStore, units: settings.units,
                authorization: location.authorization, saveToHealth: settings.saveToHealth,
                discoverySink: store)
            if outcome == .permissionDenied { showPermission = true }
            await store.load()
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
        }
        .onChange(of: coordinator.finishedRide) { _, ride in
            if ride != nil { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        }
        .onDisappear {
            router.isRideActive = false
            coordinator.cancel()
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        // Edge-swipe mirrors the back button: a just-started ride can be swiped away
        // (discard on teardown); once it's worth a summary, the swipe is disabled so a stray
        // gesture can't drop a real ride.
        .swipeBackEnabled(canDiscard)
    }
}

/// Cockpit chrome + actions, in an extension so the main type body stays under SwiftLint's
/// `type_body_length` (the pattern the navigate cockpit used). Same-file `private` members of
/// `RideHUDView` remain reachable here.
private extension RideHUDView {
    var canDiscard: Bool {
        RideBackOutGate.canDiscard(distanceMeters: coordinator.stats.distanceMeters)
    }

    /// Distance from the rider to `gem`, formatted in the rider's chosen units. Computed here
    /// (not on the store) so `GemDiscoveryStore` stays formatting-free.
    func gemDistanceText(_ gem: Gem) -> String {
        guard let here = gems?.riderCoordinate else { return "" }
        return RideStatsFormatter(units: settings.units).maneuverDistance(Geo.distance(gem.coordinate, here))
    }

    var bottomCockpit: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            HStack {
                Spacer()
                ControlCluster(
                    isFollowing: viewport.followPuck != nil,
                    onRecenter: { recenter() },
                    onEndRide: { showEndConfirm = true })
            }
            .padding(.horizontal, AuraTheme.Spacing.lg)

            ExploreInstrumentPanel(
                currentSpeedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
                units: settings.units,
                state: ExploreInstrumentState(stats: coordinator.stats,
                                              elapsed: coordinator.elapsed,
                                              units: settings.units))
                .containerRelativeFrame(.vertical, count: 4, span: 1, spacing: 0)
        }
    }

    var backButton: some View {
        Button(action: backTapped) {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.hudControl)
        .accessibilityLabel(canDiscard ? "Discard ride" : "End ride")
    }

    func backTapped() {
        if canDiscard {
            coordinator.cancel()
            router.popToRoot()
        } else {
            showEndConfirm = true
        }
    }

    /// Re-engages puck-following after the rider has panned. Snaps under Reduce Motion,
    /// flies otherwise — the same behavior navigate uses.
    func recenter() {
        if reduceMotion {
            viewport = .followPuck(zoom: 16, bearing: .heading)
        } else {
            withViewportAnimation(.easeOut(duration: 0.4)) {
                viewport = .followPuck(zoom: 16, bearing: .heading)
            }
        }
    }
}
