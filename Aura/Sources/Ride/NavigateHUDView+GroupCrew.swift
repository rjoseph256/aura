import AuraCore
import AuraKit
import SwiftUI

/// The group-ride crew chrome `NavigateHUDView` overlays on top of its map + solo HUD
/// whenever it's hosting a group ride (`groupSession != nil`). Split into its own file
/// (rather than living in `NavigateHUDView`'s main body) purely to keep that struct's
/// body under SwiftLint's `type_body_length` ceiling — none of this changes behavior on
/// the solo path, since every property here is `nil`/`false` when `groupSession` is nil.
extension NavigateHUDView {
    /// The crew layer is only meaningful while the ride is actively live; once the host
    /// has ended it (`.ended`, D9) every group-specific element disappears and the solo
    /// HUD underneath is all that remains. Always `false` on the solo path.
    var showsGroupChrome: Bool {
        groupSession?.phase == .riding
    }

    /// Self's along-route progress: the same traveled-distance number the coordinator
    /// feeds into `groupSink.locationDidUpdate(progressMeters:)`, so the roster's "ahead/
    /// behind" math and the map's route-ribbon split agree with what peers see for us.
    var selfProgressMeters: Double {
        coordinator.stats.distanceMeters
    }

    func rosterRows(for groupSession: GroupRideSession) -> [RosterRow] {
        GroupRosterViewData.rows(peers: groupSession.peers, nameMap: groupSession.nameMap,
                                 selfUserID: groupSession.selfUserID ?? UUID(),
                                 selfProgress: selfProgressMeters, isImperial: settings.units == .imperial)
    }

    var reconnectingPill: some View {
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

    /// Non-blocking affordance for a transient `end()`/`leave()` failure (ROH-68): the rider
    /// stays on this HUD — `endRide()` is never called until the server confirms `.ended` —
    /// so this chip is how they retry without losing their place. Styled identically to
    /// `reconnectingPill` (same capsule/tokens) so the crew-chrome overlay reads as one
    /// family of status pills; only its Retry action makes it interactive.
    var endFailedPill: some View {
        HStack(spacing: AuraTheme.Spacing.sm) {
            Label("Couldn't end", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
            Button("Retry") {
                Task {
                    await groupSession?.retryEndIfNeeded()
                    if groupSession?.phase == .ended { endRide() }
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(AuraTheme.accent)
        }
        .padding(.horizontal, AuraTheme.Spacing.md)
        .padding(.vertical, AuraTheme.Spacing.sm)
        .background(AuraTheme.surface.opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(AuraTheme.border))
        .accessibilityElement(children: .contain)
    }

    /// The furthest-along peer, so only one name tag renders on the map (declutters
    /// multi-peer rides) — mirrors `RideMapView`'s solo group-map leader logic.
    var groupLeaderID: UUID? {
        groupSession?.peers.filter { $0.coordinate != nil }
            .max { ($0.progressMeters ?? -.infinity) < ($1.progressMeters ?? -.infinity) }?
            .userID
    }

    // MARK: - Group End / Leave

    /// True only when this HUD is hosting a live group ride AND the rider is that ride's
    /// host. `false` for members and on the solo path.
    var isGroupHost: Bool { groupSession?.isHost == true }

    var groupEndTitle: String {
        isGroupHost ? "End the group ride for everyone?" : "Leave the crew or end your ride?"
    }

    /// Host: dissolve the crew for everyone (`end()` calls the backend, emitting the
    /// host-left wire signal so every guest's crew chrome dissolves), then finish this
    /// rider's own ride into the summary — but only once `end()` has actually landed
    /// server-side (ROH-68). A transient failure sets `groupSession.endFailed` instead of
    /// faking success; `phase` stays `.riding`, the rider stays on this HUD, and
    /// `endFailedPill`'s Retry re-attempts via `retryEndIfNeeded()`.
    func endGroupRideAsHost() {
        Task {
            await groupSession?.end()
            if groupSession?.phase == .ended { endRide() }
        }
    }

    /// Member choosing "Leave crew": drop out of the crew (chrome dissolves via phase) but
    /// keep navigating solo (D10). The ride itself is NOT ended. `leave()` can still fail
    /// transiently here (setting `endFailed`), which is acceptable — this path never calls
    /// `endRide()`, so the rider keeps navigating regardless of whether the crew-side leave
    /// has landed yet.
    func leaveCrewKeepRiding() {
        Task { await groupSession?.leave() }
    }

    /// Member choosing "End ride": leave the crew first (remove self), then finish the ride
    /// — only once the leave is server-confirmed (`.ended`), mirroring the host path above.
    func endRideAsMember() {
        Task {
            await groupSession?.leave()
            if groupSession?.phase == .ended { endRide() }
        }
    }
}
