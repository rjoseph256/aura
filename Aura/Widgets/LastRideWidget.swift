// Aura/Widgets/LastRideWidget.swift
import SwiftUI
import WidgetKit
import AuraCore
import AuraKit

/// Home + Lock Screen widget: the most recent ride at a glance — a map-free thumbnail, the
/// hero distance, and (medium) a stat column mirroring the dashboard's last-ride card.
struct LastRideWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.aura.widgets.lastRide", provider: SnapshotProvider()) { entry in
            LastRideView(entry: entry)
                .widgetURL(URL(string: entry.snapshot?.lastRide == nil ? "aura://ride" : "aura://history"))
        }
        .configurationDisplayName("Last ride")
        .description("Your most recent ride at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct LastRideView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var ride: WidgetSnapshot.LastRide? { entry.snapshot?.lastRide }
    private var units: DistanceUnits { entry.snapshot?.units ?? .imperial }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryRectangular: rectangular
        default: small
        }
    }

    private var small: some View {
        Group {
            if let ride {
                VStack(alignment: .leading, spacing: 6) {
                    RouteThumbnail(coordinates: ride.thumbnailCoordinates).frame(height: 54)
                    Spacer(minLength: 0)
                    distanceHero(ride)
                    secondaryLine(ride, "\(ride.startedAt.widgetWeekday) · \(ride.kindCaption)")
                        .font(.system(size: 11)).foregroundStyle(AuraTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            } else {
                emptyContent
            }
        }
        .padding(12)
        .containerBackground(AuraTheme.background, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var medium: some View {
        Group {
            if let ride {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        RouteThumbnail(coordinates: ride.thumbnailCoordinates)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        distanceHero(ride)
                        secondaryLine(ride, "Last ride · \(ride.startedAt.widgetWeekday)")
                            .font(.system(size: 11)).foregroundStyle(AuraTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Divider().overlay(AuraTheme.border)
                    VStack(alignment: .leading, spacing: 12) {
                        WidgetStat(label: "MOVING", value: ride.hasStats ? ride.movingTimeText : "—")
                        let climbValue = ride.hasStats
                            ? "\(fmt.elevationValue(ride.elevationGainMeters)) \(fmt.elevationUnit)"
                            : "—"
                        WidgetStat(label: "CLIMB", value: climbValue)
                    }
                    .frame(width: 92, alignment: .leading)
                }
            } else {
                emptyContent
            }
        }
        .padding(14)
        .containerBackground(AuraTheme.background, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var rectangular: some View {
        Group {
            if let ride {
                HStack(spacing: 8) {
                    RouteThumbnail(coordinates: ride.thumbnailCoordinates, lineColor: .primary)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        secondaryLine(ride, "Last ride · \(ride.startedAt.widgetWeekday)")
                            .font(.caption)
                        Text(ride.hasStats ? "\(fmt.distanceValue(ride.distanceMeters)) \(fmt.distanceUnit)" : "—")
                            .font(.headline)
                        if ride.hasStats {
                            let elev = "\(fmt.elevationValue(ride.elevationGainMeters)) \(fmt.elevationUnit)"
                            Text("\(ride.movingTimeText) · \(elev) climb").font(.caption2)
                        }
                    }
                }
            } else {
                Label("No rides yet", systemImage: "bicycle")
            }
        }
        .widgetAccentable()
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The low-value caption line each family already spends — "Tue · Explore", "Last ride ·
    /// Tue" — swapped for the no-end-recorded marker when there is one. The marker is rendered,
    /// not merely spoken: a sighted rider glancing at the Lock Screen must not see a truncated
    /// ride looking complete while a VoiceOver user is told the truth. Reusing the line costs
    /// zero height and truncates no stat, and the marker carries a glyph and words rather than a
    /// colour, so it survives the accessory families' vibrant/accented rendering.
    @ViewBuilder
    private func secondaryLine(_ ride: WidgetSnapshot.LastRide, _ caption: String) -> some View {
        if ride.isUnfinished {
            UnfinishedRideBadge(checkpointedAt: ride.checkpointedAt, style: .glance)
        } else {
            Text(caption)
        }
    }

    private func distanceHero(_ ride: WidgetSnapshot.LastRide) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(ride.hasStats ? fmt.distanceValue(ride.distanceMeters) : "—")
                .font(AuraTheme.Typography.metricCockpit(30, relativeTo: .title))
                .foregroundStyle(AuraTheme.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(fmt.distanceUnit)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bicycle").font(.title2).foregroundStyle(AuraTheme.accent)
            Spacer(minLength: 0)
            Text("No rides yet")
                .font(.system(.headline, design: .rounded)).foregroundStyle(AuraTheme.textPrimary)
            Text("Start a ride")
                .font(.system(size: 12)).foregroundStyle(AuraTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var accessibilityLabel: String {
        guard let ride else { return "No rides yet. Start a ride." }
        // The whole widget is one element, so the marker the view renders has to be repeated
        // here or it never reaches VoiceOver.
        let marker = ride.isUnfinished
            ? ". " + UnfinishedRideCopy.accessibilityLabel(checkpointedAt: ride.checkpointedAt)
            : ""
        guard ride.hasStats else { return "Last ride, \(ride.startedAt.widgetWeekday)" + marker }
        return "Last ride, \(ride.startedAt.widgetWeekday), "
            + "\(fmt.distanceValue(ride.distanceMeters)) \(fmt.distanceUnit), "
            + "moving time \(ride.movingTimeText), "
            + "\(fmt.elevationValue(ride.elevationGainMeters)) \(fmt.elevationUnit) climb"
            + marker
    }
}
