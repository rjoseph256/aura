// Aura/Sources/Ride/ShareCard/ShareCardView.swift
import SwiftUI
import AuraCore
import AuraKit

/// The shareable 4:5 ride card, rendered offscreen by `RideCardRenderer` into a PNG.
/// A static projection of `ShareCardContent`: no animation, and the renderer pins
/// `dynamicTypeSize` so the pixel output is invariant. Uses only Canvas-based renderers
/// (`RouteThumbnail`, `ElevationSparkline`) so it draws correctly through `ImageRenderer`;
/// the Mapbox map cannot render offscreen.
struct ShareCardView: View {
    let content: ShareCardContent

    /// The card is a fixed PNG viewed at feed-thumbnail scale and can't honor Increase
    /// Contrast, so text over the scrim uses the high-contrast secondary value always.
    private let scrimText = Color(white: AuraPalette.textSecondaryWhiteHighContrast)
    private var hasRoute: Bool { !content.routeCoordinates.isEmpty }
    private var hasElevation: Bool { !content.elevationSamples.isEmpty }

    var body: some View {
        Group {
            if hasRoute {
                VStack(alignment: .leading, spacing: 0) {
                    routeField
                    readoutBand
                }
            } else {
                noRouteBody
            }
        }
        .frame(width: 360, height: 450)
        .background(AuraTheme.background)
    }

    // MARK: Route field (dominant, full-bleed)

    private var routeField: some View {
        ZStack(alignment: .bottomLeading) {
            RouteThumbnail(coordinates: content.routeCoordinates,
                           lineColor: AuraTheme.routeLine, lineWidth: 3)
                .padding(AuraTheme.Spacing.lg)
            overlayBlock
                .padding(AuraTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
    }

    private var overlayBlock: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            Text(contextLine)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(scrimText)
            HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xs) {
                Text(content.distanceValue)
                    .font(AuraTheme.Typography.speedHero(56))
                    .foregroundStyle(AuraTheme.textPrimary)
                Text(content.distanceUnit)
                    .font(AuraTheme.Typography.metricCockpit(22, face: .semibold, relativeTo: .title2))
                    .foregroundStyle(scrimText)
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.md)
        .padding(.vertical, AuraTheme.Spacing.sm)
        .background(AuraTheme.surface,
                    in: RoundedRectangle(cornerRadius: AuraTheme.Radius.md, style: .continuous))
    }

    // MARK: Readout band

    private var readoutBand: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.lg) {
            if hasElevation { elevationBlock }
            metricsRow
            Spacer(minLength: 0)
            wordmark
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, AuraTheme.Spacing.xl)
        .padding(.vertical, AuraTheme.Spacing.lg)
    }

    private var elevationBlock: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            HStack(spacing: AuraTheme.Spacing.xs) {
                Image(systemName: "arrow.up.forward")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AuraTheme.accent)
                Text("\(content.climbedValue) \(content.climbedUnit) climbed")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(scrimText)
            }
            ElevationSparkline(elevations: content.elevationSamples,
                               stroke: AuraTheme.accent,
                               fill: AuraTheme.accent.opacity(0.18),
                               lineWidth: 2)
                .frame(height: 48)
        }
    }

    private var metricsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xxl) {
            StatPair(value: content.movingTime, label: "moving", context: .cockpit,
                     labelFont: .system(.subheadline, design: .rounded))
            if !hasElevation {
                StatPair(value: "\(content.climbedValue) \(content.climbedUnit)",
                         label: "climbed", context: .cockpit,
                         labelFont: .system(.subheadline, design: .rounded))
            }
        }
    }

    private var wordmark: some View {
        Text("AURA")
            .font(AuraTheme.Typography.metricCockpit(18, face: .semibold, relativeTo: .callout))
            .tracking(4)
            .foregroundStyle(AuraTheme.textPrimary)
    }

    // MARK: No-route variant (deliberate centered composition)

    private var noRouteBody: some View {
        VStack(spacing: AuraTheme.Spacing.lg) {
            Spacer()
            Text(contextLine)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(scrimText)
                .multilineTextAlignment(.center)
            VStack(spacing: AuraTheme.Spacing.xs) {
                Text(content.distanceValue)
                    .font(AuraTheme.Typography.speedHero(72))
                    .foregroundStyle(AuraTheme.textPrimary)
                Text(content.distanceUnit)
                    .font(AuraTheme.Typography.metricCockpit(20, face: .semibold, relativeTo: .title3))
                    .foregroundStyle(scrimText)
            }
            HStack(spacing: AuraTheme.Spacing.xxl) {
                StatPair(value: content.movingTime, label: "moving",
                         context: .cockpit, alignment: .center,
                         labelFont: .system(.subheadline, design: .rounded))
                StatPair(value: "\(content.climbedValue) \(content.climbedUnit)",
                         label: "climbed", context: .cockpit, alignment: .center,
                         labelFont: .system(.subheadline, design: .rounded))
            }
            Spacer()
            wordmark
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AuraTheme.Spacing.xxl)
    }

    // MARK: Context line

    private var contextLine: String {
        if let dest = content.destinationName {
            return "\(content.dateText)  ·  to \(dest)".uppercased()
        }
        return content.dateText.uppercased()
    }
}

#Preview("Route + elevation") {
    ShareCardView(content: ShareCardContent(
        ride: Ride(kind: .navigate, startedAt: Date(timeIntervalSince1970: 1_782_907_200),
                   endedAt: nil,
                   track: (0..<40).map { i in
                       TrackPoint(coordinate: Coordinate(latitude: 40.44 + Double(i) * 0.001,
                                                         longitude: -79.99 + Double(i) * 0.0012),
                                  elevation: 240 + 30 * sin(Double(i) / 4), timestamp: Date())
                   },
                   stats: RideStats(distanceMeters: 8046, movingTimeSeconds: 2520,
                                    averageSpeedMetersPerSecond: 5, maxSpeedMetersPerSecond: 9,
                                    elevationGainMeters: 73),
                   destinationName: "Millvale", routeId: nil, destinationPlaceId: nil),
        units: .imperial))
}

#Preview("No route") {
    ShareCardView(content: ShareCardContent(
        ride: Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 1_782_907_200),
                   endedAt: nil, track: [], stats: RideStats(distanceMeters: 5000,
                   movingTimeSeconds: 1200, averageSpeedMetersPerSecond: 4,
                   maxSpeedMetersPerSecond: 7, elevationGainMeters: 20),
                   destinationName: nil, routeId: nil, destinationPlaceId: nil),
        units: .imperial))
}

#Preview("Route, no elevation") {
    // Exercises the routed layout's climbed-fallback branch (metricsRow shows a second
    // StatPair) when the track has coordinates but no elevation samples.
    ShareCardView(content: ShareCardContent(
        ride: Ride(kind: .navigate, startedAt: Date(timeIntervalSince1970: 1_782_907_200),
                   endedAt: nil,
                   track: (0..<30).map { i in
                       TrackPoint(coordinate: Coordinate(latitude: 40.44 + Double(i) * 0.001,
                                                         longitude: -79.99 + Double(i) * 0.0012),
                                  elevation: nil, timestamp: Date())
                   },
                   stats: RideStats(distanceMeters: 6400, movingTimeSeconds: 1800,
                                    averageSpeedMetersPerSecond: 4, maxSpeedMetersPerSecond: 8,
                                    elevationGainMeters: 55),
                   destinationName: "Downtown", routeId: nil, destinationPlaceId: nil),
        units: .imperial))
}
