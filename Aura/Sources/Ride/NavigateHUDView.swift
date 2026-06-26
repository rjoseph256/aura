import AVFoundation
import CoreLocation
import MapboxMaps
import AuraCore
import AuraKit
import SwiftUI

/// Navigate-mode HUD with real turn-by-turn guidance.
///
/// - Full-bleed dark Mapbox map with `followPuck` viewport and a static lime
///   polyline drawn from `route.geometry`.
/// - Turn card driven by a `GuidanceViewModel`, which consumes guidance events from a
///   `GuidanceSession` (Mapbox-backed in the app, scripted in tests). The HUD itself
///   imports no guidance SDK — only the map renderer.
/// - SpeedRail bottom-trailing with live speed and elapsed time.
/// - The ride lifecycle (record, screen-wake, Live Activity, save) is owned by
///   `RideSessionCoordinator`; this view keeps guidance, voice, and the map.
struct NavigateHUDView: View {
    let route: AuraCore.Route
    /// The place the rider chose in search, denormalized onto the saved ride for History.
    var destination: Place?

    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Ride lifecycle

    @State private var coordinator: RideSessionCoordinator
    @State private var showPermission = false

    // MARK: Guidance

    /// Owns the guidance event stream and the turn-card state. Backed by Mapbox here;
    /// a `ScriptedGuidanceSession` drives the same model in tests.
    @State private var guidance = GuidanceViewModel(session: MapboxGuidanceSession())

    // MARK: Voice

    @State private var isMuted = false
    private let speechSynthesizer = AVSpeechSynthesizer()

    // MARK: Map

    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)

    init(route: AuraCore.Route, destination: Place? = nil) {
        self.route = route
        self.destination = destination
        _coordinator = State(initialValue: RideSessionCoordinator(
            kind: .navigate, destinationName: destination?.name,
            screen: ScreenWakeController(), activity: RideLiveActivityController.shared))
    }

    // MARK: Body

    var body: some View {
        @Bindable var coordinator = coordinator
        ZStack(alignment: .bottom) {
            // Full-bleed map
            navigateMapView
                .ignoresSafeArea()

            // Speed stats — bottom-trailing mirror of RideHUDView
            SpeedRail(stats: coordinator.stats, elapsed: coordinator.elapsed, units: settings.units)
                .padding(.trailing, AuraTheme.Spacing.lg)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomTrailing)

            // End-ride button
            endRideButton
        }
        // Turn card pinned below the status bar
        .overlay(alignment: .top) {
            TurnCardView(state: guidance.turn, reduceMotion: reduceMotion)
                .padding(.top, 8) // sits in the safe area; no hardcoded status-bar inset
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38),
                           value: guidance.turn)
        }
        // Mute toggle — top trailing, clear of notch
        .overlay(alignment: .topTrailing) {
            muteButton
                .padding(.top, 8)
                .padding(.trailing, 16)
        }
        // GPS signal chip — top leading, clear of the turn card (top-center) and mute button (top-trailing)
        .overlay(alignment: .topLeading) {
            GPSSignalChip(signal: location.signal)
                .padding(.top, 8).padding(.leading, 16)
        }
        // Rerouting cue — centered below the turn card (top 8 pt + ~80 pt card ≈ 88 pt;
        // 96 pt padding gives a comfortable gap). Shown only while guidance is rerouting.
        .overlay(alignment: .top) {
            if guidance.isRerouting {
                Label("Rerouting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
                    .padding(.horizontal, AuraTheme.Spacing.md)
                    .padding(.vertical, AuraTheme.Spacing.sm)
                    .background(AuraTheme.surface.opacity(0.6), in: Capsule())
                    .overlay(Capsule().strokeBorder(AuraTheme.border))
                    .padding(.top, 96)
                    .transition(.opacity)
                    .accessibilityLabel("Rerouting")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: guidance.isRerouting)
        .background(AuraTheme.background)
        // Summary sheet: when dismissed, return to plan screen.
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
                authorization: location.authorization)
            guard outcome == .started else {
                showPermission = true
                return
            }
            guidance.start(route: route)
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
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

    // MARK: Map view (puck follow + live route polyline)

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
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
    }

    // MARK: End-ride button

    private var endRideButton: some View {
        Button("End ride") {
            endRide()
        }
        .buttonStyle(.ctaDestructive)
        .padding(.horizontal, AuraTheme.Spacing.xxl)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Mute button

    private var muteButton: some View {
        Button {
            isMuted.toggle()
            if isMuted {
                speechSynthesizer.stopSpeaking(at: .immediate)
            }
        } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        // Active (muted) state shows lime; toggle trait + value convey state non-visually
        // since HUDControlButton signals "active" by color alone.
        .buttonStyle(.hudControl(active: isMuted))
        .accessibilityLabel("Mute voice guidance")
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isMuted ? "On" : "Off")
    }

    // MARK: Ride end (guidance teardown then coordinator finish)

    /// Idempotent through the coordinator: arrival and the End-ride button can both call
    /// this. Tears down guidance (view-owned) first, then finishes the ride.
    private func endRide() {
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
