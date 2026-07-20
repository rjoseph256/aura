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
    /// a `ScriptedGuidanceSession` drives the same model in tests.
    @State private var guidance = GuidanceViewModel(session: MapboxGuidanceSession())

    // MARK: Voice

    @State private var isMuted = false
    @State private var showEndConfirm = false
    /// Group-ride End/Leave confirmation. Kept separate from `showEndConfirm` so the solo
    /// End alert is byte-for-byte unchanged; only fired when `groupSession != nil`.
    @State private var showGroupEndConfirm = false
    private let speechSynthesizer = AVSpeechSynthesizer()

    // MARK: Map

    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)
    /// Each peer's previous fix, so a heading cone can be derived on-device between
    /// consecutive updates — mirrors `RideMapView`'s solo-map peer layer. Stays empty (and
    /// this state unused) whenever `groupSession` is nil.
    @State private var previousPeerCoordinates: [UUID: Coordinate] = [:]

    init(route: AuraCore.Route, destination: Place? = nil, groupSession: GroupRideSession? = nil) {
        self.route = route
        self.destination = destination
        self.groupSession = groupSession
        _coordinator = State(initialValue: RideSessionCoordinator(
            kind: .navigate, destinationName: destination?.name,
            screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
            workout: WorkoutWriter.shared))
    }

    // MARK: Body

    var body: some View {
        @Bindable var coordinator = coordinator
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
        // Turn card pinned below the status bar, with the next-turn preview beneath it.
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
        // Summary sheet: when dismissed, return to the home dashboard.
        .sheet(item: $coordinator.finishedRide, onDismiss: {
            router.popToRoot()
        }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
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

            let outcome = coordinator.start(
                location: location, saving: rideStore, units: settings.units,
                authorization: location.authorization, saveToHealth: settings.saveToHealth,
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
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
        }
        .onChange(of: coordinator.finishedRide) { _, ride in
            if ride != nil { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        }
        .onChange(of: settings.units) { _, newUnits in
            guidance.units = newUnits
        }
        .onChange(of: settings.turnHaptics) { _, on in
            guidance.hapticsEnabled = on
        }
        .onDisappear {
            router.isRideActive = false
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

            // Group-ride peer dots. `groupSession?.peers` is nil/empty on the solo path,
            // so `ForEvery` iterates zero peers and this is a no-op — the solo map is
            // visually unchanged.
            if let groupSession {
                ForEvery(GroupMapDots.visiblePeers(peers: groupSession.peers,
                                                   selfUserID: groupSession.selfUserID),
                         id: \.userID) { peer in
                    if let coordinate = peer.coordinate {
                        MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                            latitude: coordinate.latitude, longitude: coordinate.longitude)) {
                            PeerDotView(displayName: groupSession.nameMap[peer.userID] ?? peer.displayName,
                                       status: peer.status,
                                       isSelf: false,
                                       bearing: PeerBearing.heading(from: previousPeerCoordinates[peer.userID],
                                                                    to: coordinate),
                                       showsNameTag: peer.userID == groupLeaderID)
                        }
                        .allowOverlapWithPuck(true)
                    }
                }
            }
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
        .onChange(of: groupSession?.peers) { _, newPeers in
            guard let newPeers else { return }
            for peer in newPeers {
                if let coordinate = peer.coordinate {
                    previousPeerCoordinates[peer.userID] = coordinate
                }
            }
        }
    }

    // MARK: Cluster actions

    /// Re-engages puck-following after the rider has panned the map. Snaps under Reduce
    /// Motion, flies otherwise.
    private func recenter() {
        if reduceMotion {
            viewport = .followPuck(zoom: 16, bearing: .heading)
        } else {
            withViewportAnimation(.easeOut(duration: 0.4)) {
                viewport = .followPuck(zoom: 16, bearing: .heading)
            }
        }
    }

    /// Toggles voice mute; muting also cuts off any in-flight prompt.
    private func toggleMute() {
        isMuted.toggle()
        if isMuted {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
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

    // MARK: Voice

    /// Configures the audio session so spoken turn prompts duck the rider's music
    /// politely instead of stopping it. `.voicePrompt` is the navigation-prompt mode.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }

    private func speakInstruction(_ text: String) {
        guard settings.voiceEnabled, !isMuted, !text.isEmpty else { return }
        speechSynthesizer.stopSpeaking(at: .word)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }
}

private extension NavigateHUDView {
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
            // Crew status pills (Reconnecting… / Ending… / "Couldn't end — Retry") sit just
            // above the controls rather than at the top: the top-center is owned by the
            // always-present turn card (a higher-z overlay), which was occluding them there
            // (ROH-81). Here they're always visible, and the Retry chip lands right beside the
            // End button the rider just tapped. Only rendered on the group path (`showsGroupChrome`).
            if showsGroupChrome, let groupSession {
                groupStatusPills(groupSession)
            }
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
                    onMarkSpot: nil,
                    onToggleMute: { toggleMute() },
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
