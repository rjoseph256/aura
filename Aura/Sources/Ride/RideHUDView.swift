import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// The Explore (free-ride) cockpit. Auto-starts recording on appear (parity with navigate),
/// shows the bottom-pinned `ExploreInstrumentPanel` + a recenter/end `ControlCluster` over
/// the terrain map, and offers an always-visible back-out: a just-started ride (below the
/// discard floor) is discarded with no summary; once it is worth a summary, back opens the
/// End confirmation. Ending routes through the coordinator's finish → pushed summary route.
struct RideHUDView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location
    @Environment(SavedPlacesStore.self) private var savedPlaces
    @Environment(ShareMapProviderBox.self) private var shareMapBox
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
    /// Live camera for the +/- zoom pill (ROH-57). Written every frame by `RideMapView`'s
    /// `.onCameraChanged`, read only at tap time, so it never re-renders the HUD.
    @State private var cameraBox = MapZoomCameraBox()
    // This HUD is no longer solo by construction (ROH-114): a destination-free crew ride rides
    // here, with `groupSession` non-nil. Gem discovery still is not suppressed — discovery is
    // what Explore is for, and D5.3 decided the crew layer does not switch it off — so
    // `GemDiscoveryStore.isSuppressed` remains unwired, now by decision rather than by absence
    // of a caller. ROH-105 named a stale doc comment on exactly this kind of type as its
    // reusable lesson, so this one is rewritten rather than left describing the old world.
    // Built lazily in the appear .task: it needs SeenGemStore(container:) from `rideStore`,
    // which a @State initializer can't read.
    @State private var gems: GemDiscoveryStore?
    /// The mark-this-spot confirmation toast; non-nil while it's on screen. Carries the just
    /// -saved place's id so `onUndo` can delete exactly that record.
    @State private var markToast: SavedPlace?
    @State private var showSavedPlacesFull = false

    /// Builds the detour `GuidanceController` from app concretes and injects it into a fresh
    /// coordinator. `settings.units` isn't reachable here (SwiftUI environment values aren't
    /// resolved during a view's synchronous `init`), so `guidance` starts at the `.imperial`
    /// default; the live rider units still reach every on-screen distance text because
    /// `DetourOverlay` takes `units:` as a plain parameter from `settings` in `body`. Only the
    /// in-flight turn card's own formatting (sourced from `GuidanceViewModel.turn`, set once
    /// per leg in `GuidanceController.startGuidance`) would miss a metric rider's setting —
    /// a narrow, tracked gap; see Task 9 report.
    /// The crew session when a destination-free group ride is riding here, nil for a solo free
    /// ride (ROH-114 D4.1). Taken as an init parameter rather than a defaulted stored property:
    /// this type declares its own `init`, which suppresses the memberwise one, so a stored
    /// property alone would leave nothing to call. `NavigateHUDView` has the same shape.
    ///
    /// `@State` identity is positional, so the solo call site staying `RideHUDView()` keeps its
    /// state across this change.
    let groupSession: GroupRideSession?

    init(groupSession: GroupRideSession? = nil) {
        self.groupSession = groupSession
        let controller = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: MapboxGuidanceSession()) },
            routing: MapboxDetourRouting(), heading: CompassHeadingProvider(),
            haptics: HapticPlayer.shared)
        _guidance = State(initialValue: controller)
        _coordinator = State(initialValue: RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
            workout: WorkoutWriter.shared, guidance: controller, haptics: HapticPlayer.shared,
            nudges: PauseNudgeScheduler.shared))
        _showPermission = State(initialValue: false)
        _showEndConfirm = State(initialValue: false)
        _viewport = State(initialValue: .followPuck(zoom: 16, bearing: .heading))
        _gems = State(initialValue: nil)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RideMapView(segments: coordinator.segments,
                        isPaused: coordinator.isPaused,
                        gems: gems?.visiblePins ?? [],
                        seenGemIDs: gems?.seenIDs ?? [],
                        onSelectGem: { gem in gems?.select(gem) },
                        detourRoute: guidance.activeRoute?.geometry ?? [],
                        cameraBox: cameraBox,
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
        .simulatedRideProbe(distanceMeters: coordinator.stats.distanceMeters,
                            elapsed: coordinator.elapsed,
                            elevationGainMeters: coordinator.stats.elevationGainMeters,
                            speedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
                            segmentCount: coordinator.segments.count)
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
        // Mark-this-spot confirmation: sits just below the back button/GPS chip row, above
        // the detour chrome (which is rarer and more urgent when both are true).
        .overlay(alignment: .top) {
            if let place = markToast {
                MarkSpotToast(
                    message: "Marked spot saved",
                    onUndo: { savedPlaces.delete(id: place.id); markToast = nil },
                    onDismiss: { markToast = nil })
                    .padding(.horizontal, 12).padding(.top, 60)
            }
        }
        .animation(.snappy, value: markToast?.id)
        // The detour chrome (turn card / heading pointer / routing / arrival chip). Declared
        // AFTER the peek-card overlay above so it wins z-order if the two ever coexist — in
        // practice they don't, because the store arbiter (below) suppresses the peek card
        // while a detour is active.
        .overlay(alignment: .top) {
            if guidance.isDetouring || guidance.arrivalBanner != nil {
                DetourOverlay(controller: guidance, isPaused: coordinator.isPaused,
                              units: settings.units,
                              reduceMotion: reduceMotion, onStop: { guidance.cancel() })
                    .padding(.top, 8)
            }
        }
        .background(AuraTheme.background)
        .alert("End ride?", isPresented: $showEndConfirm) {
            Button("End ride", role: .destructive) { coordinator.finish() }
            Button("Keep riding", role: .cancel) { }
        }
        .alert("Saved places is full. Remove one to save another.",
               isPresented: $showSavedPlacesFull) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showPermission) {
            LocationPermissionView(onOpenSettings: RideSettingsLink.open)
        }
        .sheet(item: Binding(get: { gems?.selectedGem },
                             set: { gems?.selectedGem = $0 })) { gem in
            GemDetailSheet(
                gem: gem,
                distanceText: gemDistanceText(gem),
                canRoute: gems?.riderCoordinate != nil,
                isSavedToReturn: savedPlaces.isSaved(gemPlace(gem)),
                onTakeMeThere: {
                    guard let origin = gems?.riderCoordinate else { return }
                    gems?.selectedGem = nil                    // dismiss the sheet
                    if guidance.isDetouring {
                        guidance.retarget(gem, from: origin)   // R13
                    } else {
                        guidance.requestDetour(gem, from: origin)  // R6
                    }
                },
                onSaveToReturn: {
                    saveGemToReturn(gem)
                })
        }
        // Auto-start recording on appear (parity with navigate). A denied permission surfaces
        // the explainer; the back button (at zero distance) discards cleanly.
        .task {
            var liveProvider: any GemProviding = LiveGemProvider()
            var rideLocation: any LocationStreaming = location
            var rideAuthorization = location.authorization
            #if DEBUG
            // Golden-ride harness (ROH-92): simulated rides swap the location seam for
            // the bundled fixture, bypass the permission gate, and drop the live
            // Overpass gem source (unmocked network → nondeterministic cards).
            if let override = SimulatedRideSupport.rideOverride() {
                rideLocation = override.location
                rideAuthorization = override.authorization
                liveProvider = EmptyGemProvider()
            }
            #endif
            let store = gems ?? GemDiscoveryStore(
                provider: CompositeGemProvider(
                    local: [PersonalGemProvider(reading: savedPlaces), CuratedGemProvider()],
                    live: liveProvider),
                seen: SeenGemStore(container: rideStore.container),
                haptics: GemHapticPlayer())
            // Arbiter (R7): a detour in flight suppresses the gem peek card + Tier-3 haptic
            // (turn cues own the cockpit) but pins/seen-state are unaffected.
            //
            // KNOWN GAP, ROH-101: a detour arrival that lands while the ride is paused is
            // dropped, and the arbiter is then stuck on for the rest of the ride.
            // `GuidanceViewModel` `continue`s past `.arrivedAtDestination` while `isPaused`
            // (deliberate — see spec D7 and the comment there), and the Mapbox session yields
            // that event once, on the final-waypoint transition, so resuming does not bring it
            // back. Nothing else advances the phase: the controller's `riderDidUpdate` does
            // nothing while `.guiding`, because Mapbox is supposed to own arrival. `onArrive`
            // therefore never fires, the phase stays `.guiding`, `coordinator.isDetouring`
            // stays true, and this closure keeps returning true — gem peek cards and Tier-3 gem
            // haptics stay suppressed, and `RideMapView` keeps dimming the recorded track to 25%
            // under a stale detour polyline, until the rider notices and taps Stop on the detour
            // chip. Discovery is off with nothing on screen saying so. Narrow to reach (the rider
            // has to pause inside the gem's arrival radius in the window before Mapbox fires),
            // but silent when it happens. Re-arming guidance across a pause is out of scope for
            // this pass; the fix belongs with the device verification of the pause control.
            store.detourActive = { [coordinator] in coordinator.isDetouring }
            guidance.units = settings.units
            // Explore's detour guidance needs the paused flag too, or a rider on a "Take me
            // there" leg keeps getting turn haptics through a café stop. Navigate has always
            // set this; Explore never has. `GuidanceController` forwards to whichever
            // `GuidanceViewModel` a leg is running (and to one started while paused).
            // Voice is not in play here: the detour never sets `onSpeak`.
            coordinator.pauseObserver = guidance
            gems = store
            // groupSink attaches HERE, at `.task`, and nowhere else (ROH-114 D4.5). `start` is
            // guarded `!recorder.isRecording`, so a sink absent from the FIRST start can never
            // attach afterwards — and the failure is silent in the worst direction: the rider
            // sees the whole crew on their own map while being invisible on everyone else's,
            // because `tick` is what drives `publishIfDue`. Wiring it into the
            // `State(initialValue:)` coordinator in `init` fails the same way, capturing the
            // first init's value.
            //
            // Note both sinks are defaulted-nil on this one call, so omitting either compiles
            // clean and ships dead. That is the failure mode ROH-105 documented.
            let outcome = coordinator.start(
                location: rideLocation, saving: rideStore, units: settings.units,
                authorization: rideAuthorization, saveToHealth: settings.saveToHealth,
                groupSink: groupSession?.locationSink,
                discoverySink: store)
            if outcome == .permissionDenied { showPermission = true }
        }
        .onChange(of: coordinator.isRecording) { _, _ in
            router.activeRideID = coordinator.activeRideID
        }
        .onChange(of: coordinator.finishedRide) { _, ride in
            guard let ride else { return }
            // `activeRideID: nil` rather than `coordinator.activeRideID`: finishedRide fires after
            // `recorder.end()` dropped `isRecording`, so no ride is being recorded and this ride
            // belongs on the glance surfaces again. (Not about `checkpointedAt` — a failed save
            // leaves that set.)
            WidgetRefresh.reload(rideStore: rideStore, settings: settings, activeRideID: nil)
            shareMapBox.prefetchShareMap(for: ride, style: settings.mapStyle)
            router.showRideSummary(ride, saveFailed: coordinator.saveFailed)
        }
        .onDisappear {
            router.activeRideID = nil
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

    /// The navigable `Place` a gem would become if saved — a fresh id each call, since
    /// `SavedPlacesStore.isSaved`/`savedPlace(for:)` match by coordinate bucket
    /// (`SavedPlaceKey`), not by id.
    func gemPlace(_ gem: Gem) -> Place {
        Place(id: UUID(), name: gem.name, subtitle: nil, coordinate: gem.coordinate, category: .custom)
    }

    /// "Save to return" (Task E4): saves the gem as a resurfacing place, same shape as
    /// `markSpot()`'s save. Idempotent from the caller's side — `GemDetailSheet`'s
    /// `isSavedToReturn` disables the button once `savedPlaces.isSaved` is true, so this only
    /// ever fires from the not-yet-saved state.
    func saveGemToReturn(_ gem: Gem) {
        switch savedPlaces.save(gemPlace(gem), subtitle: nil, resurface: true) {
        case .full:
            showSavedPlacesFull = true
        case .saved:
            HapticPlayer.shared.play(.approach)
        }
    }

    var bottomCockpit: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            HStack {
                Spacer()
                ControlCluster(
                    isFollowing: viewport.followPuck != nil,
                    onRecenter: { recenter() },
                    onMarkSpot: gems?.riderCoordinate != nil ? { markSpot() } : nil,
                    onZoomIn: { zoom(.zoomIn) },
                    onZoomOut: { zoom(.zoomOut) },
                    onEndRide: { showEndConfirm = true })
            }
            .padding(.horizontal, AuraTheme.Spacing.lg)

            PauseControl(isPaused: coordinator.isPaused,
                         pausedSeconds: coordinator.currentPauseSeconds,
                         onToggle: { togglePause() })
                .padding(.horizontal, AuraTheme.Spacing.lg)

            // A fixed height, not `containerRelativeFrame(.vertical, count: 4)`. The panel's
            // contents shrink to fit the height they are given, but only down to a floor
            // (`InstrumentChassis`), and a quarter of the HUD is under that floor on every
            // device Aura supports. The panel therefore drew its floor height, 219 pt, while
            // this VStack reserved 161.75 pt for it on an iPhone SE — so the panel was centred
            // on the space it had been given and bled ~29 pt past each end of it. Before
            // ROH-101 the top bleed landed on empty map; the pause row now sits there, and on
            // an SE the panel covered its bottom 21 pt (and the CLIMB row fell off the bottom
            // of the screen). Reserving the height the panel actually draws fixes both ends.
            ExploreInstrumentPanel(
                currentSpeedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
                units: settings.units,
                state: ExploreInstrumentState(stats: coordinator.stats,
                                              elapsed: coordinator.elapsed,
                                              units: settings.units),
                isPaused: coordinator.isPaused)
                .frame(height: CGFloat(HUDLayoutMetrics.instrumentPanelHeight))
        }
    }

    /// Pause/resume from the cockpit row, returning the resulting state — which is not always
    /// the flipped one, since both coordinator calls are guarded no-ops with no ride recording.
    /// Just the state change otherwise: the VoiceOver announcement is posted inside
    /// `PauseControl`'s button action, which is shared by both HUDs, so it is written once
    /// rather than once per HUD.
    func togglePause() -> Bool {
        if coordinator.isPaused { coordinator.resume() } else { coordinator.pause() }
        return coordinator.isPaused
    }

    var backButton: some View {
        Button(action: backTapped) {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.hudControl)
        .accessibilityLabel(canDiscard ? "Discard ride" : "End ride")
        .accessibilityIdentifier(RideTestID.hudBack)
    }

    func backTapped() {
        if canDiscard {
            // `discard`, not `cancel`: the rider is throwing this ride away, so any checkpoint
            // a pause left in the store goes too. (`cancel` deliberately keeps it — it also
            // runs from `onDisappear`, which can fire without the rider asking for anything.)
            coordinator.discard()
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

    /// Steps the map zoom for a +/- tap (ROH-57). Re-follows the puck at the new zoom while
    /// following; zooms around the current center once the rider has panned off (recenter is the
    /// separate control for returning to the puck). Snaps under Reduce Motion, otherwise a quick
    /// 0.3s flick — matches the navigate HUD's `zoom`.
    func zoom(_ direction: MapZoomStep.Direction) {
        guard cameraBox.zoom.isFinite else { return }
        let target = MapZoomStep.stepped(from: cameraBox.zoom, direction)
        let next: Viewport
        if viewport.followPuck != nil {
            next = .followPuck(zoom: target, bearing: .heading)
        } else if let center = cameraBox.center {
            next = .camera(center: center, zoom: target, bearing: cameraBox.bearing, pitch: cameraBox.pitch)
        } else {
            // Panned but no camera frame yet: do nothing rather than snap back to the puck.
            return
        }
        if reduceMotion {
            viewport = next
        } else {
            withViewportAnimation(.easeOut(duration: 0.3)) { viewport = next }
        }
    }

    /// One-tap "mark this spot": saves a resurfacing place at the rider's current fix, then
    /// best-effort backfills a real name via reverse-geocode once it's back (the toast/list
    /// show the provisional "Marked spot" name until then). Guarded no-op before the first fix
    /// — `ControlCluster` also disables the button in that state, so this is a belt-and-braces
    /// check against a stale closure firing after `gems?.riderCoordinate` goes nil again.
    func markSpot() {
        guard let coordinate = gems?.riderCoordinate else { return }
        let place = Place(id: UUID(), name: "Marked spot", subtitle: nil,
                           coordinate: coordinate, category: .custom)
        switch savedPlaces.save(place, subtitle: nil, resurface: true) {
        case .full:
            showSavedPlacesFull = true
        case let .saved(saved):
            HapticPlayer.shared.play(.approach)
            markToast = saved
            Task {
                if let name = await ReverseGeocoder.name(for: coordinate) {
                    savedPlaces.updateName(id: saved.id, to: name, ifCurrentlyNamed: "Marked spot")
                }
            }
        }
    }
}

#if DEBUG
/// Harness stand-in for LiveGemProvider: contributes nothing, touches no network.
private struct EmptyGemProvider: GemProviding {
    func gems(near coordinate: Coordinate) async -> [Gem] { [] }
}
#endif
