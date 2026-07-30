import SwiftUI
import AuraCore
import AuraKit

/// The marker for a ride with no recorded end.
///
/// **Neutral, never amber.** Amber already carries peer-stopped and `AuraTheme.warning`, which
/// `GPSSignalChip` uses for weak or lost GPS — pausing under a railway bridge would otherwise
/// light two amber elements meaning different things. This is a fact about the recording, not
/// an app error, so it takes secondary weight.
///
/// **Not a pause glyph.** The rider just learned `pause.fill` and `play.fill` in the HUD, where
/// they mean "paused and resumable". Here the meaning is the opposite: this ride can never be
/// resumed or ended. A clock says "when" without promising an action.
struct UnfinishedRideBadge: View {
    let checkpointedAt: Date?

    /// `.compact` shows the label alone for dense rows; `.full` adds the detail line;
    /// `.glance` drops the capsule and inherits the caller's font and foreground, for the
    /// widget families that swap it in for an existing line and have no height to spare
    /// (and whose Lock Screen rendering must stay monochrome rather than take a fixed grey).
    enum Style { case compact, full, glance }
    var style: Style = .compact

    var body: some View {
        Group {
            if style == .glance { glance } else { capsule }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UnfinishedRideCopy.accessibilityLabel(checkpointedAt: checkpointedAt))
    }

    private var capsule: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xs) {
            Image(systemName: "clock")
                .font(.caption2.weight(.semibold))
            VStack(alignment: .leading, spacing: 1) {
                // Both lines wrap rather than truncate: at an accessibility text size this sits
                // in the narrow History column between the thumbnail and the distance numeral,
                // and a clipped marker is worst for the readers most likely to need it.
                Text(UnfinishedRideCopy.label)
                    .fixedSize(horizontal: false, vertical: true)
                if style == .full,
                   let detail = UnfinishedRideCopy.detail(checkpointedAt: checkpointedAt) {
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Footnote, not caption2: the badge competes with a 22 pt Saira distance numeral on the
        // same row, and its job is to stop the rider trusting that numeral.
        .font(.footnote.weight(.medium))
        .foregroundStyle(AuraTheme.textSecondary)
        .padding(.horizontal, AuraTheme.Spacing.sm)
        .padding(.vertical, 3)
        // A rounded rect, not a Capsule. Verified on an iPhone SE at AX5: once the label wraps
        // in the narrow History column a Capsule's radius tracks half the *height*, so the chip
        // swells into an ellipse and the text runs into its curved ends. A fixed small radius
        // still reads as a pill on the one-line case and stays a chip on the wrapped one.
        .background(AuraTheme.textSecondary.opacity(AuraPalette.unfinishedBadgeFillOpacity),
                    in: RoundedRectangle(cornerRadius: AuraTheme.Radius.sm, style: .continuous))
    }

    /// One inline line, no chrome. Deliberately carries no font or foreground of its own so a
    /// Lock Screen accessory renders it in the system's vibrant monochrome like its neighbours.
    private var glance: some View {
        Label(UnfinishedRideCopy.label, systemImage: "clock")
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

#Preview("Badge styles") {
    VStack(alignment: .leading, spacing: AuraTheme.Spacing.lg) {
        UnfinishedRideBadge(checkpointedAt: Date())
        UnfinishedRideBadge(checkpointedAt: Date(), style: .full)
        UnfinishedRideBadge(checkpointedAt: nil, style: .full)
        UnfinishedRideBadge(checkpointedAt: Date(), style: .glance)
            .font(.system(size: 11))
            .foregroundStyle(AuraTheme.textSecondary)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AuraTheme.background)
}
