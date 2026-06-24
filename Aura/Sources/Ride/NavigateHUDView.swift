import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// Navigate-mode HUD (Part A scaffold).
///
/// - Full-bleed dark Mapbox map with `followPuck` viewport and a static green
///   polyline drawn from `route.geometry`.
/// - Turn card at top showing real remaining distance to destination.
///   (Part B will replace this with per-maneuver Mapbox route-progress.)
/// - SpeedRail bottom-trailing with live speed and elapsed time.
/// - Pink "End ride" capsule → RideSummaryView sheet → returns to .plan.
struct NavigateHUDView: View {
    let route: Route

    @Environment(AppRouter.self) private var router
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

    // MARK: Turn card (Part A interim state)

    @State private var turn = TurnCardState(
        primaryText: "Arrive at destination",
        distanceText: "–",
        isExpanded: false
    )

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
        // Start ride immediately on appear
        .task { startRide() }
        .onDisappear {
            streamTask?.cancel()
            provider?.stop()
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

    // MARK: Recording lifecycle

    private func startRide() {
        let p = LiveLocationProvider()
        provider = p
        startDate = Date()
        recorder.start(at: startDate!)

        streamTask = Task { @MainActor in
            for await point in p.points() {
                recorder.record(point)
                updateTurnState(from: point)
            }
        }
    }

    private func endRide() {
        streamTask?.cancel()
        provider?.stop()
        finishedRide = recorder.end(at: Date())
    }

    // MARK: Interim turn state (Part A)

    /// Computes remaining distance to `route.destination` and drives the turn card.
    /// TODO(Task 7b): replace interim arrival-distance turn state with real Mapbox route-progress maneuvers.
    private func updateTurnState(from point: TrackPoint) {
        let remaining = Geo.distance(point.coordinate, route.destination)
        let newState = TurnCardPresenter.state(
            distanceToManeuverMeters: remaining,
            instruction: "Arrive at destination"
        )
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38)) {
            turn = newState
        }
    }
}
