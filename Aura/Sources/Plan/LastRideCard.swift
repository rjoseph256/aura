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

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        Button(action: onTap) {
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
            .padding(AuraTheme.Spacing.md)
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens ride history")
    }

    // MARK: Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        let coords = summary.thumbnailCoordinates
        let isNavigate = summary.kind == .navigate
        ZStack {
            AuraTheme.background
            if coords.count > 1 {
                // Both ride kinds draw the route in lime; the navigate-vs-free distinction
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
