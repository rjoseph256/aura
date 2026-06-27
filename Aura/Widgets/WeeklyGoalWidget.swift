// Aura/Widgets/WeeklyGoalWidget.swift
import SwiftUI
import WidgetKit
import AuraCore
import AuraKit

/// Home + Lock Screen widget: progress toward the weekly distance goal. The small family
/// mirrors the home dashboard's WeeklyRing; the Lock Screen families use system Gauges.
/// Honors the rider's units via the snapshot.
struct WeeklyGoalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.aura.widgets.weeklyGoal", provider: SnapshotProvider()) { entry in
            WeeklyGoalView(entry: entry)
                .widgetURL(URL(string: "aura://plan"))
        }
        .configurationDisplayName("Weekly goal")
        .description("Your distance this week toward your goal.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct WeeklyGoalView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var week: WidgetSnapshot.Week? { entry.snapshot?.week }
    private var units: DistanceUnits { entry.snapshot?.units ?? .imperial }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    private var small: some View {
        let week = self.week
        return VStack(spacing: 6) {
            ZStack {
                Circle().stroke(AuraTheme.border, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: week?.fraction ?? 0)
                    .stroke(AuraTheme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(fmt.distanceValue(week?.distanceMeters ?? 0))
                        .font(AuraTheme.Typography.metricCockpit(28, relativeTo: .title))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text(fmt.distanceUnit.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AuraTheme.textSecondary)
                }
            }
            Text(goalCaption(week))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AuraTheme.accent)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .padding(12)
        .containerBackground(AuraTheme.background, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance this week")
        .accessibilityValue(accessibilityValue(week))
    }

    private var circular: some View {
        Gauge(value: week?.fraction ?? 0, in: 0...1) {
            Text(fmt.distanceUnit)
        } currentValueLabel: {
            Text(fmt.distanceValue(week?.distanceMeters ?? 0))
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel("Distance this week")
        .accessibilityValue(accessibilityValue(week))
    }

    private var rectangular: some View {
        let week = self.week
        return VStack(alignment: .leading, spacing: 2) {
            Text("This week").font(.headline)
            Text("\(fmt.distanceValue(week?.distanceMeters ?? 0)) / "
                 + "\(fmt.distanceValue(week?.goalMeters ?? 0)) \(fmt.distanceUnit)")
                .font(.body)
            Gauge(value: week?.fraction ?? 0, in: 0...1) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
            Text("\(week?.percent ?? 0)% · \(week?.rideCount ?? 0) rides").font(.caption)
        }
        .widgetAccentable()
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance this week")
        .accessibilityValue(accessibilityValue(week))
    }

    private var inline: some View {
        let week = self.week
        return Label(
            "\(fmt.distanceValue(week?.distanceMeters ?? 0)) of "
                + "\(fmt.distanceValue(week?.goalMeters ?? 0)) \(fmt.distanceUnit) this week",
            systemImage: "bicycle")
            .widgetAccentable()
    }

    private func goalCaption(_ week: WidgetSnapshot.Week?) -> String {
        guard let week else { return "No rides yet" }
        return "\(week.percent)% of \(fmt.distanceValue(week.goalMeters)) \(fmt.distanceUnit)"
    }

    private func accessibilityValue(_ week: WidgetSnapshot.Week?) -> String {
        guard let week else { return "No rides yet" }
        return "\(fmt.distanceValue(week.distanceMeters)) \(fmt.distanceUnit), "
            + "\(week.percent) percent of weekly goal"
    }
}
