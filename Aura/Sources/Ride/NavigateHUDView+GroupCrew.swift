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

    /// The furthest-along peer, so only one name tag renders on the map (declutters
    /// multi-peer rides) — mirrors `RideMapView`'s solo group-map leader logic.
    var groupLeaderID: UUID? {
        groupSession?.peers.filter { $0.coordinate != nil }
            .max { ($0.progressMeters ?? -.infinity) < ($1.progressMeters ?? -.infinity) }?
            .userID
    }
}
