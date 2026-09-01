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
/// - `InstrumentPanel` (hero speed + to-go + ETA) pinned to the bottom.
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
    @Environment(ShareMapProviderBox.self) private var shareMapBox
    /// Not `private`: the cockpit row in `NavigateHUDView+Cockpit` animates off it too.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // MARK: Ride lifecycle

    @State var coordinator: RideSessionCoordinator
    @State private var showPermission = false
    /// Measured HUD height, used to cap the group roster at ~40% so a full crew never
    /// pushes the controls/instrument off a short screen. 0 until first layout.
    /// Not `private`: read by the roster frame in `NavigateHUDView+Cockpit`.
    @State var hudHeight: CGFloat = 0

    // MARK: Guidance

    /// Owns the guidance event stream and the turn-card state. Backed by Mapbox here;
    /// a `ScriptedGuidanceSession` drives the same model in tests — and, under the
    /// DEBUG golden-ride harness, an empty scripted session replaces the engine
    /// entirely (no network, no telemetry, no arrival racing the manual End; the
    /// turn card renders its unavailable state, which nothing asserts).
    /// Not `private`: the cockpit's trip strip and turn card read it across the file split.
    @State var guidance: GuidanceViewModel

    // MARK: Voice

    /// Not `private`: the mute button lives in `NavigateHUDView+Cockpit`.
    @State var isMuted = false
    @State private var showEndConfirm = false
    /// Group-ride End/Leave confirmation. Kept separate from `showEndConfirm` so the solo
    /// End alert is byte-for-byte unchanged; only fired when `groupSession != nil`.
    @State private var showGroupEndConfirm = false
    /// Not `private`: `toggleMute` (in `NavigateHUDView+Cockpit`) cuts off an in-flight prompt.
    let speechSynthesizer = AVSpeechSynthesizer()

    // MARK: Map

    /// Not `private`: the recenter/zoom controls in `NavigateHUDView+Cockpit` retarget it.
    @State var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)
    /// Live camera for the +/- zoom pill (ROH-57). Written every frame by `.onCameraChanged`;
    /// read only at tap time, so it never re-renders the HUD (see `MapZoomCameraBox`).
    /// Not `private`: the zoom pill reads it across the file split.
    @State var cameraBox = MapZoomCameraBox()
    /// Drives peer-dot interpolation, identity, and declutter (ROH-69 / ROH-72). A plain class
    /// held in `@State`; the `TimelineView` clock and `.onChange(of: peers)` drive repaints. Stays
    /// empty (a no-op) whenever `groupSession` is nil.
    @State private var peerModel = PeerAnnotationDriver()

    /// Scale bar always hidden here: the turn card owns the top-left in every HUD state, and
    /// its height varies (collapsed/expanded, one vs two lines), so no fixed margin clears it
    /// reliably — no margin assignment needed. Compass never: the recenter cluster owns
    /// orientation on a course-up HUD (spec §6.1-2).
    private var hudOrnaments: OrnamentOptions {
        var options = OrnamentOptions()
        options.scaleBar.visibility = .hidden
        options.compass.visibility = .hidden
        return options
    }

    init(route: AuraCore.Route, destination: Place? = nil, groupSession: GroupRideSession? = nil) {
        self.route = route
        self.destination = destination
        self.groupSession = groupSession
        _coordinator = State(initialValue: RideSessionCoordinator(
            kind: .navigate, destinationName: destination?.name,
            screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
            workout: WorkoutWriter.shared, haptics: HapticPlayer.shared,
            nudges: PauseNudgeScheduler.shared))
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

            // Bottom cockpit: crew roster (when hosting) + controls + the instrument
            // panel. Extracted to keep this view's body under the length limit.
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
                // Calmed while paused: the expanded card's solid mint fill would otherwise
                // compete with the mint Resume control directly below it, and a stopped rider
                // is not about to take the turn. The instruction text stays.
                TurnCardView(state: coordinator.isPaused ? guidance.turn.calmed() : guidance.turn,
                             reduceMotion: reduceMotion)
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
                            elevationGainMeters: coordinator.stats.elevationGainMeters,
                            speedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
                            segmentCount: coordinator.segments.count)
        // Rerouting cue — centered below the turn card
        .overlay(alignment: .top) {
            if guidance.isRerouting {
                Label("Rerouting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
                    .padding(.horizontal, AuraTheme.Spacing.md)
                    .padding(.vertical, AuraTheme.Spacing.sm)
                    .mapChip(Capsule())
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
            // `activeRideID: nil` rather than `coordinator.activeRideID`: finishedRide fires after
            // `recorder.end()` dropped `isRecording`, so no ride is being recorded and this ride
            // belongs on the glance surfaces again. (Not about `checkpointedAt` — a failed save
            // leaves that set.)
            WidgetRefresh.reload(rideStore: rideStore, settings: settings, activeRideID: nil)
            shareMapBox.prefetchShareMap(for: ride, style: settings.mapStyle)
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

    // MARK: Map view (puck follow + live route polyline + group peer dots)

    private var navigateMapView: some View {
        MapReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !peerModel.shouldAnimate(now: Date()))) { context in
                Map(viewport: $viewport) {
                    // Rider puck follows heading
                    Puck2D(bearing: .heading)
                        .topImage(AuraPuck.clearTop)
                        .bearingImage(AuraPuck.ridingBearing)
                        .shadowImage(nil)

                    // Live route line: ONE lineMetrics source under two layers that differ only
                    // in the property on their last line. The bright layer trims itself away
                    // behind the rider, uncovering the dim one — that IS the traveled-dim, and
                    // it is why the dim is declared first: the content tree re-asserts
                    // declaration-order layer positions every pass, so this ordering is the
                    // z-order. Keep the emptiness guard — an empty source/layer pair still
                    // mounts style objects per map mount (see `RideMapView.routeRibbon`).
                    if (guidance.routeGeometry ?? route.geometry).count > 1 {
                        routeSource
                        routeLayer(id: "aura-nav-route-dim").lineOpacity(AuraPalette.routeDimOpacity)
                        routeLayer(id: "aura-nav-route-bright").lineTrimOffset(start: 0, end: trimEnd)

                        // Destination flag at the drawn geometry's end — it follows a reroute,
                        // because `guidance.routeGeometry` is what is stroked above. Inside the
                        // line's own guard, as in `RoutePreviewView` and `RideMapView`: no line,
                        // no flag.
                        //
                        // This sits inside the 30 Hz `TimelineView`, so: identity is structural
                        // (a fixed position in the content tree, so `tryUpdate` reuses the same
                        // hosting controller frame after frame) and the coordinate is derived
                        // from an array's `last` — O(1), no per-frame geometry walk, and the
                        // content closure builds a field-less view. `.allowOverlapWithPuck(true)`
                        // because the default would hide the flag exactly on final approach.
                        if let destination = (guidance.routeGeometry ?? route.geometry).last {
                            MapViewAnnotation(
                                coordinate: CLLocationCoordinate2D(latitude: destination.latitude,
                                                                   longitude: destination.longitude)
                            ) {
                                DestinationMarkerView()
                            }
                            .allowOverlapWithPuck(true)
                        }
                    }

                    // Group-ride peer dots. On the solo path `frame.dots` is empty, so this is a
                    // no-op and the map is visually unchanged.
                    // Camera bearing comes through the proxy, not `cameraBox`: reading the
                    // @Observable box here would subscribe this body to a property that
                    // `.onCameraChanged` writes every camera frame — the re-render feedback the
                    // box exists to avoid. The proxy read is plain state, refreshed by the same
                    // 30fps timeline that already drives the dots.
                    PeerAnnotations(frame: peerModel.frame(
                        now: context.date,
                        cameraBearing: proxy.map?.cameraState.bearing ?? 0,
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
                // `.ornamentOptions(_:)` also returns `Map`, so it must stay in this chain too —
                // same reasoning as `.onCameraChanged` above.
                .ornamentOptions(hudOrnaments)
            }
        }
        .onAppear { syncPeers() }
        .onChange(of: groupSession?.peers) { syncPeers() }
        .onChange(of: reduceMotion) { syncPeers() }
    }

    // MARK: End-tap routing (solo vs group)

    /// Solo path (groupSession nil) is unchanged: open the solo End alert. On the group
    /// path, open the host/member confirmation dialog instead. Not `private`: the End
    /// button that calls it lives in `NavigateHUDView+Cockpit`.
    func onEndTapped() {
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

/// Map plumbing + voice, in an extension so the main type body stays under SwiftLint's
/// `type_body_length` (the pattern `RideHUDView` uses). Same-file `private` members of
/// `NavigateHUDView` remain reachable here. The cockpit itself lives in
/// `NavigateHUDView+Cockpit.swift`.
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
}

/// The navigate traveled-dim (ROH-221): one `lineMetrics` source under two `LineLayer`s, the
/// bright one trimming itself away behind the rider to uncover the dim one. An extension rather
/// than the struct body only to stay under SwiftLint's `type_body_length`.
extension NavigateHUDView {
    static var routeSourceID: String { "aura-nav-route" }

    /// The single source under both layers, carrying the post-reroute geometry once guidance
    /// has one and the planned route's until then (`GuidanceViewModel` updates it on every
    /// reroute). `lineMetrics` is REQUIRED by `lineTrimOffset` and its absence is not a no-op —
    /// the line vanishes with a Metal shader error (mapbox-maps-ios#1927); that is also why
    /// this is a style source rather than a `PolylineAnnotationGroup`, whose manager hardcodes
    /// a source without metrics. Rebuilt as a *value* per content pass (this sits in a 30 Hz
    /// `TimelineView` on group rides) but never re-uploaded: the SDK pushes GeoJSON only when
    /// `data` differs, so a progress tick moves the trim and touches nothing here.
    var routeSource: GeoJSONSource {
        let coordinates = (guidance.routeGeometry ?? route.geometry).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        var source = GeoJSONSource(id: Self.routeSourceID)
        source.data = .feature(Feature(geometry: LineString(coordinates)))
        source.lineMetrics = true
        return source
    }

    /// The stroke BOTH layers share — the dim one adds only `lineOpacity`, the bright one only
    /// `lineTrimOffset`, so the ridden span keeps the exact footprint of the road ahead. Were it
    /// narrower or uncased, the trim boundary would be a moving step in the line's *shape*
    /// rather than a change in its weight. 9 − 2×1.5 = 6pt of visible mint: Mapbox draws
    /// `lineBorderWidth` INSIDE `lineWidth`, not outside it, so this is the same core the
    /// navigate line drew before the dim (the arithmetic is in `RoutePreviewView`).
    func routeLayer(id: String) -> LineLayer {
        LineLayer(id: id, source: Self.routeSourceID)
            .lineColor(StyleColor(AuraTheme.routeUIColor))
            .lineWidth(9)
            .lineBorderColor(StyleColor(AuraTheme.routeCasingUIColor))
            .lineBorderWidth(1.5)
            .lineCap(.round)
            .lineJoin(.round)
    }

    /// Paint-only traveled trim. While rerouting — which spans the WHOLE fetch window — and
    /// until a fresh post-reroute fraction arrives (`.rerouted` nils the stale one), this is 0:
    /// a full bright line, never a wrong dim. Both guards are load-bearing and neither subsumes
    /// the other. A Mapbox route *refresh* can change `routeId` with no preceding
    /// `FetchingRoute`, so `.rerouted` lands with `isRerouting` already false — the nil-fraction
    /// check covers that. And a session can yield `.progress` before `.rerouted` inside one sink
    /// call, pairing a NEW fraction with OLD geometry — `isRerouting` covers that.
    var trimEnd: Double {
        guard !guidance.isRerouting,
              let fraction = guidance.lastUpdate?.fractionTraveled else { return 0 }
        return RouteTrim.quantized(fraction)
    }
}
