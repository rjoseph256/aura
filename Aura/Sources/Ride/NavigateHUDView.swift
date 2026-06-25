import AVFoundation
import CoreLocation
import MapboxMaps
import AuraCore
import AuraKit
import SwiftUI

/// Navigate-mode HUD with real turn-by-turn guidance.
///
/// - Full-bleed dark Mapbox map with `followPuck` viewport and a static green
///   polyline drawn from `route.geometry`.
/// - Turn card driven by a `GuidanceViewModel`, which consumes guidance events from a
///   `GuidanceSession` (Mapbox-backed in the app, scripted in tests). The HUD itself
///   imports no guidance SDK — only the map renderer.
/// - SpeedRail bottom-trailing with live speed and elapsed time.
/// - Pink "End ride" capsule → RideSummaryView sheet → returns to .plan.
/// - Mute toggle (top-trailing) for spoken instructions via AVSpeechSynthesizer.
struct NavigateHUDView: View {
    let route: AuraCore.Route
    /// The place the rider chose in search, denormalized onto the saved ride for History.
    var destination: Place?

    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Recording

    @State private var recorder = RideRecorder(kind: .navigate)
    @State private var streamTask: Task<Void, Never>?
    @State private var finishedRide: Ride?
    @State private var saveFailed = false
    @State private var showPermission = false

    // MARK: Guidance

    /// Owns the guidance event stream and the turn-card state. Backed by Mapbox here;
    /// a `ScriptedGuidanceSession` drives the same model in tests.
    @State private var guidance = GuidanceViewModel(session: MapboxGuidanceSession())

    // MARK: Elapsed-time ticker

    @State private var startDate: Date?
    @State private var now = Date()

    private var elapsed: TimeInterval {
        guard let startDate else { return 0 }
        return now.timeIntervalSince(startDate)
    }

    // MARK: Voice

    @State private var isMuted = false
    private let speechSynthesizer = AVSpeechSynthesizer()

    // MARK: Map

    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)

    // MARK: Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-bleed map
            navigateMapView
                .ignoresSafeArea()

            // Speed stats — bottom-trailing mirror of RideHUDView
            SpeedRail(stats: recorder.stats, elapsed: elapsed, units: settings.units)
                .padding(.trailing, 14)
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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                    .padding(.top, 96)
                    .transition(.opacity)
                    .accessibilityLabel("Rerouting")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: guidance.isRerouting)
        .background(AuraTheme.bg)
        // Summary sheet: when dismissed, return to plan screen.
        .sheet(item: $finishedRide, onDismiss: {
            router.screen = .plan
        }) { ride in
            RideSummaryView(ride: ride, saveFailed: saveFailed)
        }
        .sheet(isPresented: $showPermission) {
            LocationPermissionView(onOpenSettings: openSettings)
        }
        // Elapsed-time ticker (mirrors RideHUDView pattern)
        .task(id: recorder.isRecording) {
            guard recorder.isRecording else { return }
            while !Task.isCancelled {
                now = Date()
                // The controller throttles internally and pushes immediately on a new
                // maneuver, so ticking it here keeps the next turn current on the
                // Lock Screen / Dynamic Island without a separate timer.
                RideLiveActivityController.shared.update(
                    stats: recorder.stats, maneuver: guidance.lastUpdate)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        // Start recording + guidance immediately on appear
        .task {
            isMuted = !settings.voiceEnabled
            configureAudioSession()
            guidance.onSpeak = { speakInstruction($0) }
            guidance.onArrive = { endRide() }

            // Gate: do not start recording or guidance when permission is denied.
            switch location.authorization {
            case .denied, .restricted:
                showPermission = true
                return
            default:
                break
            }

            startRide()
            if let startDate {
                RideLiveActivityController.shared.start(
                    mode: .navigate, startedAt: startDate, units: settings.units,
                    destinationName: destination?.name)
            }
            guidance.start(route: route)
        }
        .onDisappear {
            teardownGuidance()
            location.stop()
            RideScreen.keepAwake(false)
        }
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
                    // TODO(Wave 2): replace hardcoded route color with an AuraTheme StyleColor bridge
                    .lineColor(StyleColor(UIColor(red: 43 / 255,
                                                  green: 224 / 255,
                                                  blue: 138 / 255,
                                                  alpha: 1)))
                    .lineWidth(6)
                }
            }
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
    }

    // MARK: End-ride button

    private var endRideButton: some View {
        Button {
            endRide()
        } label: {
            Text("End ride")
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(AuraTheme.pink, in: Capsule())
                .frame(minHeight: 56)
        }
        .padding(.horizontal, 24)
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
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(isMuted ? "Unmute voice guidance" : "Mute voice guidance")
    }

    // MARK: Recording lifecycle

    private func startRide() {
        startDate = Date()
        recorder.start(at: startDate!)
        RideScreen.keepAwake(true)

        streamTask = Task { @MainActor in
            for await point in location.points() {
                recorder.record(point)
                // Turn state is driven by the GuidanceViewModel; recording only here.
            }
        }
    }

    private func endRide() {
        // Idempotent: arrival and the End-ride button can both call this; once
        // recording has stopped there's nothing more to do.
        guard recorder.isRecording else { return }
        streamTask?.cancel()
        location.stop()
        RideScreen.keepAwake(false)
        teardownGuidance()
        RideLiveActivityController.shared.end()
        let ride = recorder.end(at: Date(), destinationName: destination?.name)
        do { try rideStore.save(ride) } catch { saveFailed = true }
        finishedRide = ride
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

    // MARK: Settings deep-link

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
