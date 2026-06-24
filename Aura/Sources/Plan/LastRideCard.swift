import SwiftUI
import AuraCore
import AuraKit

/// Compact summary of the rider's most recent ride on the home screen: a route
/// thumbnail (the same `StaticRouteMap` History will reuse), the destination, its
/// distance + duration, and a relative date. Taps through to the History tab.
struct LastRideCard: View {
    let ride: Ride
    let units: DistanceUnits
    let onTap: () -> Void

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                thumbnail
                    .frame(width: 88, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AuraTheme.text)
                        .lineLimit(1)
                    Text(statsLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AuraTheme.muted)
                    Text(relativeDate)
                        .font(.system(size: 12))
                        .foregroundStyle(AuraTheme.muted.opacity(0.85))
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AuraTheme.muted)
            }
            .padding(12)
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens ride history")
    }

    // MARK: Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        let coords = ride.track.map(\.coordinate)
        if coords.count > 1 {
            StaticRouteMap(coordinates: coords)
        } else {
            // No track to draw (e.g. a free ride with no GPS fix) — show an icon tile
            // rather than an empty basemap.
            ZStack {
                AuraTheme.bg
                Image(systemName: ride.kind == .navigate ? "location.fill" : "bicycle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AuraTheme.muted)
            }
        }
    }

    // MARK: Text

    private var title: String {
        if let name = ride.destinationName, !name.isEmpty { return name }
        return ride.kind == .navigate ? "Ride" : "Free ride"
    }

    private var statsLine: String {
        guard let s = ride.stats else { return "—" }
        return "\(fmt.distanceValue(s.distanceMeters)) \(fmt.distanceUnit) · \(fmt.minutes(s.movingTimeSeconds))"
    }

    private var relativeDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(ride.startedAt) { return "Today" }
        if cal.isDateInYesterday(ride.startedAt) { return "Yesterday" }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: ride.startedAt),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        if days >= 2 && days < 7 { return "\(days) days ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: ride.startedAt)
    }
}
