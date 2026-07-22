import SwiftUI
import AuraCore
import AuraKit

// MARK: - RouteOptionRow

struct RouteOptionRow: View {
    let route: Route
    let units: DistanceUnits
    let isSelected: Bool
    let reduceMotion: Bool
    /// Shared elevation scale across all options (nil → self-scale).
    var elevationRange: ClosedRange<Double>?
    let onTap: () -> Void

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    private var label: String {
        switch route.profile {
        case .mostPaths: return "Most paths"
        case .fastest:   return "Fastest"
        case .flattest:  return "Flattest"
        }
    }

    private var glyph: String {
        switch route.profile {
        case .mostPaths: return "leaf.fill"
        case .fastest:   return "bolt.fill"
        case .flattest:  return "chart.line.flattrend.xyaxis"
        }
    }

    private var metricText: String {
        var text = "\(fmt.distanceValue(route.distanceMeters)) \(fmt.distanceUnit) · \(fmt.minutes(route.estimatedDurationSeconds))"
        if route.elevationGainMeters > 0 {
            text += " · \(fmt.elevationValue(route.elevationGainMeters)) \(fmt.elevationUnit)↑"
        }
        return text
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AuraTheme.Spacing.lg) {
                Image(systemName: glyph)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? AuraTheme.onAccent : AuraTheme.textPrimary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.headline)
                        .foregroundStyle(isSelected ? AuraTheme.onAccent : AuraTheme.textPrimary)
                    Text(metricText)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? AuraTheme.onAccent : AuraTheme.textSecondary)
                }

                Spacer(minLength: AuraTheme.Spacing.sm)

                // Elevation profile — lets the rider compare hilliness across options.
                if route.elevationProfile.count > 1 {
                    ElevationSparkline(
                        elevations: route.elevationProfile,
                        stroke: isSelected ? AuraTheme.onAccent : AuraTheme.accent,
                        fill: isSelected ? AuraTheme.onAccent.opacity(0.16) : AuraTheme.accent.opacity(0.16),
                        range: elevationRange
                    )
                    .frame(width: 54, height: 26)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AuraTheme.onAccent)
                }
            }
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .padding(.vertical, AuraTheme.Spacing.lg)
            .frame(minHeight: 56)
            .background(
                isSelected
                    ? AnyShapeStyle(AuraTheme.accent)
                    : AnyShapeStyle(AuraTheme.surface),
                in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSelected)
    }
}

// MARK: - SkeletonRow

struct SkeletonRow: View {
    let reduceMotion: Bool
    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.lg) {
            RoundedRectangle(cornerRadius: AuraTheme.Radius.sm, style: .continuous)
                .fill(AuraTheme.surface)
                .frame(width: 24, height: 20)
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
                RoundedRectangle(cornerRadius: AuraTheme.Radius.xs, style: .continuous)
                    .fill(AuraTheme.surface)
                    .frame(width: 100, height: 14)
                RoundedRectangle(cornerRadius: AuraTheme.Radius.xs, style: .continuous)
                    .fill(AuraTheme.surface)
                    .frame(width: 140, height: 11)
            }
            Spacer()
        }
        .padding(.horizontal, AuraTheme.Spacing.lg)
        .padding(.vertical, AuraTheme.Spacing.lg)
        .frame(minHeight: 56)
        .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
        .opacity(reduceMotion ? 1.0 : (pulse ? 0.45 : 0.9))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            ) {
                pulse = true
            }
        }
    }
}
