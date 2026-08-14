import SwiftUI
import AuraCore
import AuraKit

/// Thin adapter from a `GroupRideSession` to the `NavigateHUDView` it rides on top of.
/// `NavigateHUDView` now owns the whole crew layer itself (peer dots on the map, the
/// roster sheet, membership toasts, and the "Reconnecting…" pill) whenever it's handed a
/// non-nil `groupSession` — see Task 17. This container's only remaining job is picking
/// the session's route (or a sane fallback) and passing the session through.
struct GroupNavigateContainer: View {
    let session: GroupRideSession

    var body: some View {
        if let route = session.route {
            NavigateHUDView(route: route, destination: nil, groupSession: session)
        } else {
            // Unreachable, and now for a stronger reason than before: `GroupRideFlowView`
            // routes by the ride's stored `kind`, so a destination-free ride never arrives
            // here at all (ROH-114 D4.1) — it rides the Explore cockpit. Only a route ride
            // reaches this type, and its route is set before `phase` leaves `.idle`. Kept as
            // a sane fallback rather than a crash.
            Color.clear
        }
    }
}

// MARK: - Previews

#Preview("Riding — crew chrome visible") {
    GroupNavigateContainerPreviewHost(phase: .riding, isLive: true)
        .environment(AppRouter())
        .environment(previewRideStore())
        .environment(SettingsStore())
        .environment(LocationService())
        .preferredColorScheme(.dark)
}

#Preview("Ended — chrome gone, solo HUD persists") {
    GroupNavigateContainerPreviewHost(phase: .ended, isLive: true)
        .environment(AppRouter())
        .environment(previewRideStore())
        .environment(SettingsStore())
        .environment(LocationService())
        .preferredColorScheme(.dark)
}

#Preview("Reconnecting pill") {
    GroupNavigateContainerPreviewHost(phase: .riding, isLive: false)
        .environment(AppRouter())
        .environment(previewRideStore())
        .environment(SettingsStore())
        .environment(LocationService())
        .preferredColorScheme(.dark)
}

/// An in-memory `RideStore` for these previews. `NavigateHUDView` (which
/// `GroupNavigateContainer` now hosts directly) reads `RideStore` from the environment
/// even in a group ride, so the preview needs one — an in-memory container should never
/// fail to build, so a crash here would only ever surface a real regression.
@MainActor
private func previewRideStore() -> RideStore {
    // swiftlint:disable:next force_try
    try! RideStore.inMemory()
}

/// Drives a real `GroupRideSession` against in-memory fakes (no network) into the requested
/// phase/liveness so the container's chrome-visibility rules can be previewed directly.
private struct GroupNavigateContainerPreviewHost: View {
    let phase: GroupRideSession.Phase
    let isLive: Bool

    @State private var session: GroupRideSession

    init(phase: GroupRideSession.Phase, isLive: Bool) {
        self.phase = phase
        self.isLive = isLive
        _session = State(initialValue: GroupRideSession(
            backend: InMemoryGroupRideBackend(), transport: InMemoryRideSessionTransport(),
            displayNameProvider: { "Jamie Rivera" }))
    }

    var body: some View {
        GroupNavigateContainer(session: session)
            .task {
                let route = Route(id: UUID(),
                                  origin: Coordinate(latitude: 40.44, longitude: -79.99),
                                  destination: Coordinate(latitude: 40.46, longitude: -79.95),
                                  waypoints: [], geometry: [], profile: .fastest,
                                  distanceMeters: 8_000, estimatedDurationSeconds: 1_800,
                                  elevationGainMeters: 60)
                await session.create(route: route)
                await session.startRiding()
                await session.beginLiveSession()

                let peerID = UUID()
                await session.ingest(.connected)
                await session.ingest(.position(LivePositionPayload(
                    userID: peerID, coordinate: route.origin, progressMeters: 500,
                    recordedAt: Date(), motionState: .moving)))

                if !isLive {
                    await session.ingest(.disconnected(nil))
                }
                if phase == .ended {
                    // `.rideEnded` is the host-end wire signal (Task 7 removed the old
                    // `.memberLeft(hostID)` heuristic) — the same broadcast a real "host
                    // tapped End" sends, which moves this session to `.ended` and dissolves
                    // the crew chrome.
                    await session.ingest(.rideEnded)
                }
            }
    }
}
