import SwiftUI
import AuraCore
import AuraKit

/// Composes the group-ride crew chrome on top of the existing solo `NavigateHUDView`.
/// `NavigateHUDView` itself is untouched — it keeps recording, guiding, and saving the ride
/// exactly as it does for a solo rider. This container only adds a floating layer above it:
/// the crew roster sheet, membership toasts, and a "Reconnecting…" pill, all bound to one
/// `GroupRideSession`.
///
/// Group chrome is visible only while `session.phase == .riding`. Once the host ends the
/// ride (D9: `phase == .ended`), the chrome is hidden — but `NavigateHUDView` is left running
/// underneath, so the rider keeps navigating to their destination solo rather than being
/// booted out of an in-progress ride.
struct GroupNavigateContainer: View {
    let session: GroupRideSession

    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ZStack(alignment: .bottom) {
            if let route = session.route {
                NavigateHUDView(route: route, destination: nil)
            } else {
                // Guarded per the brief: `.riding` with no route is unreachable in practice
                // (create/join both set `route` before this phase), but render something
                // sane rather than a blank screen.
                Color.clear
            }

            if showsGroupChrome {
                GroupRosterSheet(rows: rosterRows)
                    .padding(.horizontal, AuraTheme.Spacing.md)
                    .padding(.bottom, AuraTheme.Spacing.xxxl)
            }
        }
        .overlay(alignment: .top) {
            if showsGroupChrome {
                GroupToastHost(events: session.toasts)
            }
        }
        .overlay(alignment: .top) {
            if showsGroupChrome, !session.isLive {
                reconnectingPill
                    .padding(.top, 44)
            }
        }
    }

    /// The crew layer is only meaningful while the ride is actively live; once the host has
    /// ended it (`.ended`), every group-specific element disappears and the solo HUD beneath
    /// is all that remains.
    private var showsGroupChrome: Bool {
        session.phase == .riding
    }

    private var rosterRows: [RosterRow] {
        GroupRosterViewData.rows(peers: session.peers, nameMap: session.nameMap,
                                 selfUserID: session.selfUserID ?? UUID(),
                                 selfProgress: 0, isImperial: settings.units == .imperial)
    }

    private var reconnectingPill: some View {
        Label("Reconnecting…", systemImage: "wifi.exclamationmark")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AuraTheme.textPrimary)
            .padding(.horizontal, AuraTheme.Spacing.md)
            .padding(.vertical, AuraTheme.Spacing.sm)
            .background(AuraTheme.surface.opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(AuraTheme.border))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reconnecting to the group ride")
    }
}

// MARK: - Previews

#Preview("Riding — crew chrome visible") {
    GroupNavigateContainerPreviewHost(phase: .riding, isLive: true)
        .environment(SettingsStore())
        .preferredColorScheme(.dark)
}

#Preview("Ended — chrome gone, solo HUD persists") {
    GroupNavigateContainerPreviewHost(phase: .ended, isLive: true)
        .environment(SettingsStore())
        .preferredColorScheme(.dark)
}

#Preview("Reconnecting pill") {
    GroupNavigateContainerPreviewHost(phase: .riding, isLive: false)
        .environment(SettingsStore())
        .preferredColorScheme(.dark)
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
                session.startRiding()
                await session.beginLiveSession()

                let peerID = UUID()
                await session.ingest(.connected)
                await session.ingest(.position(LivePositionPayload(
                    userID: peerID, coordinate: route.origin, progressMeters: 500,
                    recordedAt: Date(), motionState: .moving)))

                if !isLive {
                    await session.ingest(.disconnected(nil))
                }
                if phase == .ended, let hostID = session.selfUserID {
                    // This preview session is always its own host (it called `create`), so a
                    // `.memberLeft` matching self's id is what `GroupRideSession` recognizes
                    // as the host ending the ride (D9) — the same signal a real "host tapped
                    // End" would send over the wire.
                    await session.ingest(.memberLeft(hostID))
                }
            }
    }
}
