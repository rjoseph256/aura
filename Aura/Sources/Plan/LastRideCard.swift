import SwiftUI
import AuraCore
import AuraKit

/// Compact summary of the rider's most recent ride on the home screen: a route
/// thumbnail (the same `StaticRouteMap` History will reuse), the destination, its
/// distance + duration, and a relative date. Taps through to the History tab.
struct LastRideCard: View {
    let summary: RideSummary
    let units: DistanceUnits
    let onTap: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
                cardRow
                // Full width, under the row rather than inside the text column. That column is
                // hemmed in by an 88 pt thumbnail and the chevron, and on an iPhone SE at AX5 it
                // broke the label one syllable per line and pushed the card clean out of the
                // Home peek. Here it wraps to two lines at worst.
                if summary.isUnfinished {
                    UnfinishedRideBadge(checkpointedAt: summary.checkpointedAt)
                }
            }
            .padding(AuraTheme.Spacing.md)
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens ride history")
    }

    private var cardRow: some View {
        HStack(spacing: AuraTheme.Spacing.lg) {
            thumbnail
                .frame(width: 88, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
                    .lineLimit(1)
                Text(statsLine)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AuraTheme.textSecondary)
                Text(relativeDate)
                    .font(.caption)
                    .foregroundStyle(AuraTheme.textSecondary)
            }

            Spacer(minLength: AuraTheme.Spacing.xs)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }

    // MARK: Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        let coords = summary.thumbnailCoordinates
        let isNavigate = summary.kind == .navigate
        ZStack {
            AuraTheme.background
            // Subtle terrain foreshadow behind the route line (Chunk 3 medal thread); off
            // under Reduce Transparency where extra texture would only reduce legibility.
            if !reduceTransparency { ContourForeshadow().opacity(0.12) }
            if coords.count > 1 {
                // Both ride kinds draw the route in mint; the navigate-vs-free distinction
                // is carried non-chromatically by the line weight (a navigated route reads
                // heavier than a casual free ride), not by hue.
                RouteThumbnail(coordinates: coords,
                               lineColor: AuraTheme.accent,
                               lineWidth: isNavigate ? 3 : 2)
                    .padding(AuraTheme.Spacing.xs)
            } else {
                // No track to draw (e.g. a free ride with no GPS fix) — show an icon.
                // The glyph alone distinguishes the kind: a directional bearing vs a bike.
                Image(systemName: isNavigate ? "location.north.line.fill" : "bicycle")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
    }

    // MARK: Text

    private var title: String {
        if let name = summary.destinationName, !name.isEmpty { return name }
        return summary.kind == .navigate ? "Ride" : "Explore"
    }

    private var statsLine: String {
        guard summary.hasStats else { return "—" }
        return "\(fmt.distanceValue(summary.distanceMeters)) \(fmt.distanceUnit) · \(fmt.minutes(summary.movingTimeSeconds))"
    }

    private var relativeDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(summary.startedAt) { return "Today" }
        if cal.isDateInYesterday(summary.startedAt) { return "Yesterday" }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: summary.startedAt),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        if days >= 2 && days < 7 { return "\(days) days ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: summary.startedAt)
    }
}

/// A faint terrain-contour motif drawn behind the route thumbnail on the last-ride card —
/// a restrained foreshadow of the Chunk 3 terrain-carved summary medal. Decorative only,
/// never behind text; the caller drops it under Reduce Transparency.
private struct ContourForeshadow: View {
    var body: some View {
        Canvas { ctx, size in
            let lines = 5
            for i in 0..<lines {
                let y = size.height * (CGFloat(i) + 0.5) / CGFloat(lines)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addQuadCurve(to: CGPoint(x: size.width, y: y),
                                  control: CGPoint(x: size.width / 2, y: y - 7 + CGFloat(i) * 3))
                ctx.stroke(path, with: .color(AuraTheme.accent), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}
