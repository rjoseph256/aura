import AVFoundation
import CoreLocation
import MapboxMaps
import AuraCore
import AuraKit
import SwiftUI

/// Navigate-mode HUD with real turn-by-turn guidance.
///
/// - Full-bleed dark Mapbox map with `followPuck` viewport and a static mint
///   polyline drawn from `route.geometry`.
/// - Turn card driven by a `GuidanceViewModel`, which consumes guidance events from a
///   `GuidanceSession` (Mapbox-backed in the app, scripted in tests). The HUD itself
///   imports no guidance SDK — only the map renderer.
/// - Quarter-screen `InstrumentPanel` (hero speed + to-go + ETA) pinned to the bottom.
/// - The ride lifecycle (record, screen-wake, Live Activity, save) is owned by
///   `RideSessionCoordinator`; this view keeps guidance, voice, and the map.
struct NavigateHUDView: View {
    let route: AuraCore.Route
    /// The place the rider chose in search, denormalized onto the saved ride for History.
    var destination: Place?
    /// Non-nil only when this HUD is hosting a group ride (set by `GroupNavigateContainer`).
    /// Solo navigation (the default `nil`) is completely unaffected by anything gated on
    /// this: no `groupSink` is passed to the coordinator, no peer dots are added to the
    /// map, and no crew chrome is overlaid.
    var groupSession: GroupRideSession?

    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) var settings
    @Environment(LocationService.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    // MARK: Ride lifecycle

    @State var coordinator: RideSessionCoordinator
    @State private var showPermission = false
    /// Measured HUD height, used to cap the group roster at ~40% so a full crew never
    /// pushes the controls/instrument off a short screen. 0 until first layout.
    @State private var hudHeight: CGFloat = 0

    // MARK: Guidance

    /// Owns the guidance event stream and the turn-card state. Backed by Mapbox here;
    /// a `ScriptedGuidanceSession` drives the same model in tests — and, under the
    /// DEBUG golden-ride harness, an empty scripted session replaces the engine
    /// entirely (no network, no telemetry, no arrival racing the manual End; the
    /// turn card renders its unavailable state, which nothing asserts).
    @State private var guidance: GuidanceViewModel

    // MARK: Voice

    @State private var isMuted = false
    @State private var showEndConfirm = false
    /// Group-ride End/Leave confirmation. Kept separate from `showEndConfirm` so the solo
    /// End alert is byte-for-byte unchanged; only fired when `groupSession != nil`.
    @State private var showGroupEndConfirm = false
    private let speechSynthesizer = AVSpeechSynthesizer()

    // MARK: Map

    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)
    /// Live camera for the +/- zoom pill (ROH-57). Written every frame by `.onCameraChanged`;
    /// read only at tap time, so it never re-renders the HUD (see `MapZoomCameraBox`).
    @State private var cameraBox = MapZoomCameraBox()
    /// Drives peer-dot interpolation, identity, and declutter (ROH-69 / ROH-72). A plain class
    /// held in `@State`; the `TimelineView` clock and `.onChange(of: peers)` drive repaints. Stays
    /// empty (a no-op) whenever `groupSession` is nil.
    @State private var peerModel = PeerAnnotationDriver()

    init(route: AuraCore.Route, destination: Place? = nil, groupSession: GroupRideSession? = nil) {
        self.route = route
        self.destination = destination
        self.groupSession = groupSession
        _coordinator = State(initialValue: RideSessionCoordinator(
            kind: .navigate, destinationName: destination?.name,
            screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
            workout: WorkoutWriter.shared))
        #if DEBUG
        if SimulatedRideConfig.current != nil {
            _guidance = State(initialValue:
                GuidanceViewModel(session: ScriptedGuidanceSession(script: [])))
        } else {
            _guidance = State(initialValue:
                GuidanceViewModel(session: MapboxGuidanceSession()))
        }
        #else
        _guidance = State(initialValue:
            GuidanceViewModel(session: MapboxGuidanceSession()))
        #endif
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-bleed map
            navigateMapView
                .ignoresSafeArea()

            // Bottom cockpit: crew roster (when hosting) + controls + quarter-screen
            // instrument panel. Extracted to keep this view's body under the length limit.
            bottomCockpit
        }
        // Crew membership toasts
        .overlay(alignment: .top) {
            if showsGroupChrome, let groupSession {
                GroupToastHost(events: groupSession.toasts)
            }
        }
        // Turn card pinned below the status bar, with the next-turn preview beneath it, and —
        // on a group ride — the crew status pills (Reconnecting… / Ending… / "Couldn't end —
        // Retry") tucked tight under that banner cluster. The pills live in THIS overlay (not a
        // top overlay of their own) because the turn card is a higher-z top overlay that would
        // otherwise occlude them (ROH-81); nesting here keeps them just below the card and
        // moving with it as it resizes, always visible and tappable.
        .overlay(alignment: .top) {
            VStack(spacing: AuraTheme.Spacing.sm) {
                TurnCardView(state: guidance.turn, reduceMotion: reduceMotion)
                if let update = guidance.lastUpdate,
                   let next = TurnCardPresenter.nextManeuver(for: update) {
                    ThenChip(next: next)
                        .transition(reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity))
                }
                if showsGroupChrome, let groupSession {
                    groupStatusPills(groupSession)
                }
            }
            .padding(.top, 8) // sits in the safe area; no hardcoded status-bar inset
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38),
                       value: guidance.turn)
        }
        // GPS signal chip — top leading
        .overlay(alignment: .topLeading) {
            GPSSignalChip(signal: location.signal)
                .padding(.top, 8).padding(.leading, 16)
        }
        .simulatedRideProbe(distanceMeters: coordinator.stats.distanceMeters,
                            elapsed: coordinator.elapsed,
                            elevationGainMeters: coordinator.stats.elevationGainMeters)
        // Rerouting cue — centered below the turn card
        .overlay(alignment: .top) {
            if guidance.isRerouting {
                Label("Rerouting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
                    .padding(.horizontal, AuraTheme.Spacing.md)
                    .padding(.vertical, AuraTheme.Spacing.sm)
                    .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast), in: Capsule())
                    .overlay(Capsule().strokeBorder(AuraTheme.hairline(contrast)))
                    .padding(.top, 96)
                    .transition(.opacity)
                    .accessibilityLabel("Rerouting")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: guidance.isRerouting)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hudHeight = $0 }
        .background(AuraTheme.background)
        // End-ride confirmation: the cluster's End button opens this. An alert (not a
        // confirmationDialog) is used so the "Keep riding" cancel button reliably renders
        // and stays VoiceOver-reachable in this full-screen HUD; an action sheet's cancel
        // was being clipped here.
        .alert("End ride?", isPresented: $showEndConfirm) {
            Button("End ride", role: .destructive) { endRide() }
            Button("Keep riding", role: .cancel) { }
        }
        // Group-ride End/Leave confirmation. Host ends the ride for everyone (dissolves the
        // crew via the host-left wire signal) then finishes their own ride; a member leaves
        // the crew (D10 — they keep navigating solo) or ends their own ride (leave first,
        // then finish). Only presented on the group path; the solo alert above is untouched.
        .confirmationDialog(groupEndTitle, isPresented: $showGroupEndConfirm, titleVisibility: .visible) {
            if isGroupHost {
                Button("End group ride", role: .destructive) { endGroupRideAsHost() }
                Button("Keep riding", role: .cancel) { }
            } else {
                Button("Leave crew") { leaveCrewKeepRiding() }
                Button("End ride", role: .destructive) { endRideAsMember() }
                Button("Keep riding", role: .cancel) { }
            }
        }
        // ROH-81: acknowledge a waited-on end/leave the moment it starts + announce/haptic the
        // outcome — feedback the top-of-screen pill alone can miss. (Extracted to +GroupCrew.)
        .groupEndFeedback(isEnding: groupSession?.isEnding, endFailed: groupSession?.endFailed)
        .sheet(isPresented: $showPermission) {
            LocationPermissionView(onOpenSettings: RideSettingsLink.open)
        }
        // Keep the coordinator's Live Activity turn current as guidance progresses.
        .onChange(of: guidance.lastUpdate) { _, update in
            coordinator.maneuver = update
        }
        // Start recording + guidance on appear. The voice/audio front matter stays ahead
        // of coordinator.start so its ordering is unchanged.
        .task {
            isMuted = !settings.voiceEnabled
            configureAudioSession()
            guidance.onSpeak = { speakInstruction($0) }
            guidance.onArrive = { endRide() }
            // Arrival and voice are suppressed while paused: riders pause *at* the destination,
            // inside the arrival radius, and `onArrive` ends the ride with no confirmation.
            // Wired as a direct observer rather than an `.onChange` so guidance learns about
            // the pause in the same turn as the tap — the turn in between is exactly when a
            // pending arrival would fire. Set here so it is live the moment Pass 4's control is.
            coordinator.pauseObserver = guidance

            var rideLocation: any LocationStreaming = location
            var rideAuthorization = location.authorization
            #if DEBUG
            // Golden-ride harness (ROH-93): same seam swap as the free-ride HUD, via
            // the shared helper, so both paths feed identical simulated input.
            if let override = SimulatedRideSupport.rideOverride() {
                rideLocation = override.location
                rideAuthorization = override.authorization
            }
            #endif
            let outcome = coordinator.start(
                location: rideLocation, saving: rideStore, units: settings.units,
                authorization: rideAuthorization, saveToHealth: settings.saveToHealth,
                groupSink: groupSession?.locationSink)
            guard outcome == .started else {
                showPermission = true
                return
            }
            guidance.haptics = HapticPlayer.shared
            guidance.hapticsEnabled = settings.turnHaptics
            guidance.units = settings.units
            guidance.start(route: route)
        }
        .onChange(of: coordinator.isRecording) { _, _ in
            // Stays non-nil across a pause — a paused ride is an active ride, and this id is
            // the only thing stopping a deep link from tearing the HUD down into `cancel()`,
            // which does not save (spec D6/D7).
            router.activeRideID = coordinator.activeRideID
        }
        .onChange(of: coordinator.finishedRide) { _, ride in
            guard let ride else { return }
            // Refresh widgets BEFORE navigating: showRideSummary collapses the path and tears
            // this HUD down. saveFailed is already set by finish() (before finishedRide), so it
            // reads correctly here. (ROH-85)
            // finishedRide fires after finish() cleared the marker, so no ride is active.
            WidgetRefresh.reload(rideStore: rideStore, settings: settings, activeRideID: nil)
            router.showRideSummary(ride, saveFailed: coordinator.saveFailed)
        }
        .onChange(of: settings.units) { _, newUnits in
            guidance.units = newUnits
        }
        .onChange(of: settings.turnHaptics) { _, on in
            guidance.hapticsEnabled = on
        }
        .onDisappear {
            router.activeRideID = nil
            teardownGuidance()
            coordinator.cancel()
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled(false)
    }

    /// The formatted trip strip line, recomputed each render from the latest guidance
    /// update and the current time. nil update (pre-guidance) reads as `.starting`.
    private var cruisingState: CruisingState {
        guard let update = guidance.lastUpdate else { return .starting }
        return CruisingPresenter.state(for: update, units: settings.units, now: Date())
    }

    // MARK: Map view (puck follow + live route polyline + group peer dots)

    private var navigateMapView: some View {
        MapReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !peerModel.shouldAnimate(now: Date()))) { context in
                Map(viewport: $viewport) {
                    // Rider puck follows heading
                    Puck2D(bearing: .heading)

                    // Live route polyline: switches to the post-reroute geometry when available.
                    // guidance.routeGeometry is updated by GuidanceViewModel on each reroute event.
                    if (guidance.routeGeometry ?? route.geometry).count > 1 {
                        PolylineAnnotationGroup {
                            PolylineAnnotation(
                                lineCoordinates: (guidance.routeGeometry ?? route.geometry).map {
                                    CLLocationCoordinate2D(latitude: $0.latitude,
                                                           longitude: $0.longitude)
                                }
                            )
                            .lineColor(StyleColor(AuraTheme.routeUIColor))
                            .lineWidth(6)
                        }
                    }

                    // Group-ride peer dots. On the solo path `frame.dots` is empty, so this is a
                    // no-op and the map is visually unchanged.
                    PeerAnnotations(frame: peerModel.frame(now: context.date,
                                                           project: { project($0, proxy) }))
                }
                .mapStyle(settings.mapStyle.mapboxStyle)
                // Mirror the live camera into the zoom box. Must stay in the Map modifier chain
                // (before any type-erasing View modifier) or the Map-only API is dropped.
                .onCameraChanged { ctx in
                    cameraBox.zoom = ctx.cameraState.zoom
                    cameraBox.center = ctx.cameraState.center
                    cameraBox.bearing = ctx.cameraState.bearing
                    cameraBox.pitch = ctx.cameraState.pitch
                }
            }
        }
        .onAppear { syncPeers() }
        .onChange(of: groupSession?.peers) { syncPeers() }
        .onChange(of: reduceMotion) { syncPeers() }
    }

    // MARK: End-tap routing (solo vs group)

    /// Solo path (groupSession nil) is unchanged: open the solo End alert. On the group
    /// path, open the host/member confirmation dialog instead.
    private func onEndTapped() {
        if groupSession != nil {
            showGroupEndConfirm = true
        } else {
            showEndConfirm = true
        }
    }

    // MARK: Ride end (guidance teardown then coordinator finish)

    /// Idempotent through the coordinator: arrival and the End-ride button can both call
    /// this. Tears down guidance (view-owned) first, then finishes the ride. `internal`
    /// (not `private`) so the group End/Leave actions in `NavigateHUDView+GroupCrew` can
    /// finish the rider's own ride after the crew lifecycle call.
    func endRide() {
        teardownGuidance()
        coordinator.finish()
    }

    // MARK: Guidance teardown

    /// Stops the guidance session and releases the audio session. The Mapbox-specific
    /// teardown (subscriptions, free-drive) lives in `MapboxGuidanceSession.stop()`.
    private func teardownGuidance() {
        guidance.stop()
        speechSynthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Cockpit chrome + actions, in an extension so the main type body stays under SwiftLint's
/// `type_body_length` (the pattern `RideHUDView` uses). Same-file `private` members of
/// `NavigateHUDView` remain reachable here.
private extension NavigateHUDView {
    /// Real Mapbox projection for declutter; nil when the coordinate is off-screen/unavailable.
    func project(_ c: Coordinate, _ proxy: MapProxy) -> ClusterDeclutter.Point2D? {
        guard let map = proxy.map else { return nil }
        let pt = map.point(for: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
        guard pt.x.isFinite, pt.y.isFinite else { return nil }
        return ClusterDeclutter.Point2D(x: Double(pt.x), y: Double(pt.y))
    }

    func syncPeers() {
        guard let groupSession else {
            peerModel.updateSet(peers: [], selfUserID: nil, nameMap: [:],
                                reduceMotion: reduceMotion, now: Date())
            return
        }
        peerModel.updateSet(peers: groupSession.peers, selfUserID: groupSession.selfUserID,
                            nameMap: groupSession.nameMap, reduceMotion: reduceMotion, now: Date())
    }

    // MARK: Cluster actions

    /// Re-engages puck-following after the rider has panned the map. Snaps under Reduce
    /// Motion, flies otherwise.
    func recenter() {
        if reduceMotion {
            viewport = .followPuck(zoom: 16, bearing: .heading)
        } else {
            withViewportAnimation(.easeOut(duration: 0.4)) {
                viewport = .followPuck(zoom: 16, bearing: .heading)
            }
        }
    }

    /// Toggles voice mute; muting also cuts off any in-flight prompt.
    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: Voice

    /// Configures the audio session so spoken turn prompts duck the rider's music
    /// politely instead of stopping it. `.voicePrompt` is the navigation-prompt mode.
    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }

    func speakInstruction(_ text: String) {
        guard settings.voiceEnabled, !isMuted, !text.isEmpty else { return }
        speechSynthesizer.stopSpeaking(at: .word)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    /// Steps the map zoom for a +/- tap (ROH-57). While following the puck it re-follows at the
    /// new zoom (staying locked on the rider); once the rider has panned off, it zooms around the
    /// current center instead of snapping back — recenter is the separate control for that. Snaps
    /// under Reduce Motion, otherwise a quick 0.3s flick (a smaller camera move than recenter's
    /// re-frame, so a hair snappier on purpose).
    func zoom(_ direction: MapZoomStep.Direction) {
        guard cameraBox.zoom.isFinite else { return }
        let target = MapZoomStep.stepped(from: cameraBox.zoom, direction)
        let next: Viewport
        if viewport.followPuck != nil {
            next = .followPuck(zoom: target, bearing: .heading)
        } else if let center = cameraBox.center {
            next = .camera(center: center, zoom: target, bearing: cameraBox.bearing, pitch: cameraBox.pitch)
        } else {
            // Panned off the puck but no camera frame yet (pre-first-`onCameraChanged`): do
            // nothing rather than snap back to the puck, which zoom must never do.
            return
        }
        if reduceMotion {
            viewport = next
        } else {
            withViewportAnimation(.easeOut(duration: 0.3)) { viewport = next }
        }
    }

    /// The bottom cockpit: a crew-roster + map-controls row floating above the quarter-screen
    /// instrument panel (hero speed + to-go + ETA). The roster (only in a live group ride)
    /// shares that row with the controls as a pill to their left, its bottom edge aligned
    /// with the End (stop) button — bottom alignment keeps the collapsed one-line pill beside
    /// the stop button, and expanding it grows upward, capped at ~40% of the HUD so a full
    /// crew can't push the controls off a short screen. Solo rides keep the controls
    /// right-aligned via the Spacer fallback. (D9 hides the roster once the host ends the
    /// ride; the solo path never renders it.)
    @ViewBuilder var bottomCockpit: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            HStack(alignment: .bottom, spacing: AuraTheme.Spacing.md) {
                if showsGroupChrome, let groupSession {
                    GroupRosterSheet(rows: rosterRows(for: groupSession))
                        .frame(maxHeight: hudHeight > 0 ? hudHeight * 0.4 : 320, alignment: .bottom)
                } else {
                    Spacer(minLength: 0)
                }
                ControlCluster(
                    isFollowing: viewport.followPuck != nil,
                    isMuted: isMuted,
                    onRecenter: { recenter() },
                    // Navigate has no mark-this-spot feature, so omit the button entirely rather
                    // than show it permanently disabled — that also keeps the taller (zoom pill)
                    // cluster clear of the turn card on a short screen (ROH-57).
                    showMarkSpot: false,
                    onToggleMute: { toggleMute() },
                    onZoomIn: { zoom(.zoomIn) },
                    onZoomOut: { zoom(.zoomOut) },
                    onEndRide: { onEndTapped() },
                    isEndDisabled: groupSession?.isEnding == true)
            }
            .padding(.horizontal, AuraTheme.Spacing.lg)

            InstrumentPanel(
                currentSpeedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
                units: settings.units,
                trip: cruisingState)
                .containerRelativeFrame(.vertical, count: 4, span: 1, spacing: 0)
        }
    }
}
