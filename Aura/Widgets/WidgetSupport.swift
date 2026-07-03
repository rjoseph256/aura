// Aura/Widgets/WidgetSupport.swift
import SwiftUI
import AuraCore
import AuraKit

extension Date {
    /// Abbreviated weekday, e.g. "Tue".
    var widgetWeekday: String { formatted(.dateTime.weekday(.abbreviated)) }
}

extension WidgetSnapshot.LastRide {
    /// "Explore" or the navigated destination name.
    var kindCaption: String {
        kind == .navigate ? (destinationName ?? "Ride") : "Explore"
    }
    /// Moving time as "1:02" (h:mm) for an hour or more, else "12:30" (m:ss).
    var movingTimeText: String {
        Duration.seconds(movingTimeSeconds)
            .formatted(.time(pattern: movingTimeSeconds >= 3600 ? .hourMinute : .minuteSecond))
    }
}

/// A small cockpit stat cell for the medium widget: a Saira value over a muted label.
struct WidgetStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
            Text(value)
                .font(AuraTheme.Typography.metricCockpit(18, relativeTo: .body))
                .foregroundStyle(AuraTheme.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1)
        }
    }
}
