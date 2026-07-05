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

    @State private var coordinator = RideSessionCoordinator(
        kind: .freeRide, destinationName: nil,
        screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
        workout: WorkoutWriter.shared)
    @State private var showPermission = false
    @State private var showEndConfirm = false
    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)
    // Free rides are solo by construction — group rides use NavigateHUDView +
    // GroupRideSession, never this HUD — so gem discovery is never suppressed here.
    // (GemDiscoveryStore.isSuppressed exists for a future group-explore surface.)
    // Built lazily in the appear .task: it needs SeenGemStore(container:) from `rideStore`,
    // which a @State initializer can't read.
    @State private var gems: GemDiscoveryStore?

    var body: some View {
        @Bindable var coordinator = coordinator
        ZStack(alignment: .bottom) {
            RideMapView(track: coordinator.track,
                        gems: gems?.visiblePins ?? [],
                        seenGemIDs: gems?.seenIDs ?? [],
                        onSelectGem: { gem in gems?.select(gem) },
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
        .overlay(alignment: .bottom) {
            if let store = gems, let gem = store.activeCard {
                GemPeekCard(gem: gem, distanceText: gemDistanceText(gem),
                            onTap: { store.select(gem); store.dismissActiveCard() },
                            onDismiss: { store.dismissActiveCard() })
                    .padding(.horizontal, 12).padding(.bottom, 120)
            }
        }
        .animation(.snappy, value: gems?.activeCard?.id)
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
            GemDetailSheet(gem: gem, distanceText: gemDistanceText(gem))
        }
        // Auto-start recording on appear (parity with navigate). A denied permission surfaces
        // the explainer; the back button (at zero distance) discards cleanly.
        .task {
            let store = gems ?? GemDiscoveryStore(
                provider: CuratedGemProvider(),
                seen: SeenGemStore(container: rideStore.container),
                haptics: GemHapticPlayer())
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
