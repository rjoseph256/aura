import AVFoundation
import Combine
import CoreLocation
import MapboxDirections
import MapboxMaps
import MapboxNavigationCore
import AuraCore
import AuraKit
import SwiftUI

/// Navigate-mode HUD with real Mapbox turn-by-turn guidance (Part B).
///
/// - Full-bleed dark Mapbox map with `followPuck` viewport and a static green
///   polyline drawn from `route.geometry`.
/// - Turn card driven by live `NavigationController.routeProgress` maneuver data.
/// - SpeedRail bottom-trailing with live speed and elapsed time.
/// - Pink "End ride" capsule → RideSummaryView sheet → returns to .plan.
/// - Mute toggle (top-trailing) for spoken instructions via AVSpeechSynthesizer.
struct NavigateHUDView: View {
    let route: AuraCore.Route

    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Recording

    @State private var recorder = RideRecorder(kind: .navigate)
    @State private var provider: (any LocationStreaming)?
    @State private var streamTask: Task<Void, Never>?
    @State private var finishedRide: Ride?

    // MARK: Elapsed-time ticker

    @State private var startDate: Date?
    @State private var now = Date()

    private var elapsed: TimeInterval {
        guard let startDate else { return 0 }
        return now.timeIntervalSince(startDate)
    }

    // MARK: Turn card (driven by real route progress in Part B)

    @State private var turn = TurnCardState(
        primaryText: "Starting navigation…",
        distanceText: "–",
        isExpanded: false
    )

    // MARK: Guidance subscriptions

    /// Cancellables for Combine subscriptions to route progress and voice instructions.
    @State private var guidanceCancellables = Set<AnyCancellable>()

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
            SpeedRail(stats: recorder.stats, elapsed: elapsed)
                .padding(.trailing, 14)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomTrailing)

            // End-ride button
            endRideButton
        }
        // Turn card pinned below the status bar
        .overlay(alignment: .top) {
            TurnCardView(state: turn, reduceMotion: reduceMotion)
                .padding(.top, 56) // clear status bar
        }
        // Mute toggle — top trailing, clear of notch
        .overlay(alignment: .topTrailing) {
            muteButton
                .padding(.top, 56)
                .padding(.trailing, 16)
        }
        .background(AuraTheme.bg)
        // Summary sheet: when dismissed, return to plan screen.
        .sheet(item: $finishedRide, onDismiss: {
            router.screen = .plan
        }) { ride in
            RideSummaryView(ride: ride)
        }
        // Elapsed-time ticker (mirrors RideHUDView pattern)
        .task(id: recorder.isRecording) {
            guard recorder.isRecording else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        // Start recording + guidance immediately on appear
        .task {
            startRide()
            await startGuidance()
        }
        .onDisappear {
            stopGuidance()
        }
    }

    // MARK: Map view (puck follow + static route polyline)

    private var navigateMapView: some View {
        Map(viewport: $viewport) {
            // Rider puck follows heading
            Puck2D(bearing: .heading)

            // Static green route polyline drawn from geometry
            if route.geometry.count > 1 {
                PolylineAnnotationGroup {
                    PolylineAnnotation(
                        lineCoordinates: route.geometry.map {
                            CLLocationCoordinate2D(latitude: $0.latitude,
                                                   longitude: $0.longitude)
                        }
                    )
                    .lineColor(StyleColor(UIColor(red: 43 / 255,
                                                  green: 224 / 255,
                                                  blue: 138 / 255,
                                                  alpha: 1)))
                    .lineWidth(6)
                }
            }
        }
        .mapStyle(.dark)
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
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(isMuted ? "Unmute voice guidance" : "Mute voice guidance")
    }

    // MARK: Recording lifecycle

    private func startRide() {
        let p = LiveLocationProvider()
        provider = p
        startDate = Date()
        recorder.start(at: startDate!)

        streamTask = Task { @MainActor in
            for await point in p.points() {
                recorder.record(point)
                // Turn state is now driven by Mapbox route progress.
                // Recording-only here; guidance task drives `turn`.
            }
        }
    }

    private func endRide() {
        // Idempotent: arrival (waypointsArrival) and the End-ride button can both
        // call this; once recording has stopped there's nothing more to do.
        guard recorder.isRecording else { return }
        streamTask?.cancel()
        provider?.stop()
        stopGuidance()
        let ride = recorder.end(at: Date())
        try? rideStore.save(ride)
        finishedRide = ride
    }

    // MARK: Guidance lifecycle

    /// Fetches routes and starts Mapbox active guidance, then subscribes to
    /// route-progress and voice-instruction publishers.
    ///
    /// NOTE: Re-fetching the route here keeps the app's route model (AuraCore.Route)
    /// decoupled from the Mapbox NavigationRoutes type. The guided route will normally
    /// match the previewed one. Fidelity to the exact selected alternative/profile is
    /// a later enhancement (Task 8).
    @MainActor
    private func startGuidance() async {
        // Defensive: guarantee a single set of subscriptions / one active guidance session
        // even if this is ever invoked more than once.
        guidanceCancellables.removeAll()
        configureAudioSession()

        let originCoord = CLLocationCoordinate2D(
            latitude: route.origin.latitude,
            longitude: route.origin.longitude
        )
        let destCoord = CLLocationCoordinate2D(
            latitude: route.destination.latitude,
            longitude: route.destination.longitude
        )

        let options = NavigationRouteOptions(
            waypoints: [
                MapboxDirections.Waypoint(coordinate: originCoord),
                MapboxDirections.Waypoint(coordinate: destCoord)
            ],
            profileIdentifier: .cycling
        )
        options.includesAlternativeRoutes = false

        do {
            let navRoutes = try await AuraNavigation.provider.mapboxNavigation
                .routingProvider()
                .calculateRoutes(options: options)
                .value

            // Start active turn-by-turn guidance.
            AuraNavigation.provider.mapboxNavigation
                .tripSession()
                .startActiveGuidance(with: navRoutes, startLegIndex: 0)

            // Subscribe to route progress → drive the turn card.
            AuraNavigation.provider.mapboxNavigation
                .navigation()
                .routeProgress
                .receive(on: DispatchQueue.main)
                .sink { [self] state in
                    guard let progress = state?.routeProgress else { return }
                    handleRouteProgress(progress)
                }
                .store(in: &guidanceCancellables)

            // Subscribe to arrival events → end ride automatically at final destination.
            AuraNavigation.provider.mapboxNavigation
                .navigation()
                .waypointsArrival
                .receive(on: DispatchQueue.main)
                .sink { [self] status in
                    if status.event is WaypointArrivalStatus.Events.ToFinalDestination {
                        endRide()
                    }
                }
                .store(in: &guidanceCancellables)

            // Subscribe to voice instructions → speak via AVSpeechSynthesizer.
            AuraNavigation.provider.mapboxNavigation
                .navigation()
                .voiceInstructions
                .receive(on: DispatchQueue.main)
                .sink { [self] state in
                    speakInstruction(state.spokenInstruction.text)
                }
                .store(in: &guidanceCancellables)

        } catch {
            // Guidance fetch failed — fall back to interim arrival-distance turn state.
            // Recording and map puck still work; turn card degrades gracefully.
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38)) {
                turn = TurnCardState(
                    primaryText: "Navigate to destination",
                    distanceText: "–",
                    isExpanded: false
                )
            }
        }
    }

    private func stopGuidance() {
        guidanceCancellables.removeAll()
        speechSynthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // Return to free-drive so the SDK session stays warm for next ride.
        AuraNavigation.provider.mapboxNavigation.tripSession().startFreeDrive()
    }

    // MARK: Route-progress handler

    /// Extracts the current step's remaining distance + instruction text and
    /// drives the TurnCardView via TurnCardPresenter.
    @MainActor
    private func handleRouteProgress(_ progress: RouteProgress) {
        let stepProgress = progress.currentLegProgress.currentStepProgress
        let distanceRemaining = stepProgress.distanceRemaining

        // Prefer the upcoming step's instruction (what you're approaching),
        // falling back to the current step instruction, then a generic label.
        let instructionText: String
        if let upcoming = progress.currentLegProgress.upcomingStep {
            instructionText = upcoming.instructions
        } else {
            instructionText = progress.currentLegProgress.currentStep.instructions
        }

        let newState = TurnCardPresenter.state(
            distanceToManeuverMeters: distanceRemaining,
            instruction: instructionText
        )
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38)) {
            turn = newState
        }
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
        guard !isMuted, !text.isEmpty else { return }
        speechSynthesizer.stopSpeaking(at: .word)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }
}
