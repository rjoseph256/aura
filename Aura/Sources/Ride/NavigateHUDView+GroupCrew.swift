import AuraCore
import AuraKit
import SwiftUI
import UIKit

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

    /// Immediate acknowledgment that a waited-on end/leave is in flight (ROH-81). Styled
    /// identically to `reconnectingPill`/`endFailedPill` so the crew chrome reads as one family.
    /// Only shown for host-end / member-end (a keep-riding leave never sets `isEnding`), so the
    /// "Ending…" wording is always accurate.
    var endingPill: some View {
        HStack(spacing: AuraTheme.Spacing.sm) {
            ProgressView().controlSize(.small).tint(AuraTheme.accent)
            Text("Ending…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
        }
        .padding(.horizontal, AuraTheme.Spacing.md)
        .padding(.vertical, AuraTheme.Spacing.sm)
        .background(AuraTheme.surface.opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(AuraTheme.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ending the group ride")
    }

    /// The stacked crew status pills (ending / reconnecting / end-failed). Extracted from
    /// `NavigateHUDView`'s body to keep it under the length limit; at most one shows in practice
    /// (`endFailed` is only set after `isEnding` clears).
    @ViewBuilder
    func groupStatusPills(_ groupSession: GroupRideSession) -> some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            if groupSession.isEnding {
                endingPill
            }
            if !groupSession.isLive {
                reconnectingPill
            }
            if groupSession.endFailed {
                endFailedPill
            }
        }
        .padding(.top, 44)
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
            await groupSession?.endAsMember()
            if groupSession?.phase == .ended { endRide() }
        }
    }
}

/// Announces (VoiceOver) and haptically signals a waited-on end/leave outcome — feedback the
/// top-of-screen "Ending…" pill alone can miss for a host looking at the map or using VoiceOver
/// (ROH-81). Both inputs are `Bool?` so the optional `groupSession` composes cleanly.
struct GroupEndFeedback: ViewModifier {
    let isEnding: Bool?
    let endFailed: Bool?
    func body(content: Content) -> some View {
        content
            .onChange(of: isEnding) { _, value in
                if value == true {
                    AccessibilityNotification.Announcement("Ending the group ride").post()
                }
            }
            .onChange(of: endFailed) { _, value in
                if value == true {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    AccessibilityNotification.Announcement("Couldn't end the group ride. Retry available.").post()
                }
            }
    }
}

extension View {
    /// Applies `GroupEndFeedback` for a group ride's `isEnding`/`endFailed` transitions.
    func groupEndFeedback(isEnding: Bool?, endFailed: Bool?) -> some View {
        modifier(GroupEndFeedback(isEnding: isEnding, endFailed: endFailed))
    }
}
