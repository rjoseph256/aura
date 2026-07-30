// Aura/Sources/Ride/ShareCard/ShareCardView.swift
import SwiftUI
import AuraCore
import AuraKit

/// The shareable 4:5 ride card, rendered offscreen by `RideCardRenderer` into a PNG.
/// A static projection of `ShareCardContent`: no animation, and the renderer pins
/// `dynamicTypeSize` so the pixel output is invariant. The map field shows a pre-rendered
/// `Snapshotter` raster when one was accepted (`mapImage`); a live Mapbox `Map` still
/// cannot render through `ImageRenderer`, so the fallback draws the Canvas-based
/// `RouteThumbnail` instead. Geometry comes from `ShareCardLayout` (AuraKit), whose
/// package test measures the band budget against the shipped Saira faces.
struct ShareCardView: View {
    let content: ShareCardContent
    /// An accepted, composited map raster at exactly `ShareCardLayout.mapFieldSize` @3x,
    /// or `nil` for the polyline fallback. Required — a defaulted parameter here would be
    /// a permanent seam where a forgotten argument silently ships the fallback card.
    let mapImage: UIImage?

    /// The card is a fixed PNG viewed at feed-thumbnail scale and can't honor Increase
    /// Contrast, so secondary text uses the high-contrast secondary value always.
    private let scrimText = Color(white: AuraPalette.textSecondaryWhiteHighContrast)
    private var hasRoute: Bool { !content.routeSegments.isEmpty }
    private var hasElevation: Bool { !content.elevationSamples.isEmpty }

    var body: some View {
        Group {
            if hasRoute {
                VStack(alignment: .leading, spacing: 0) {
                    mapField
                    readoutBand
                }
            } else {
                noRouteBody
            }
        }
        .frame(width: ShareCardLayout.cardSize.width, height: ShareCardLayout.cardSize.height)
        .background(AuraTheme.background)
    }

    // MARK: Map field (full-bleed top, nothing of ours over it)

    private var mapField: some View {
        Group {
            if let mapImage {
                // `resizable` is load-bearing: a disk-cache round-trip re-materializes at
                // scale 1 unless re-wrapped, and the exact 360×240 aspect match means the
                // stretch cannot distort and the SDK's attribution corners can't be cropped.
                Image(uiImage: mapImage)
                    .resizable()
            } else {
                RouteThumbnail(segments: content.routeSegments,
                               lineColor: AuraTheme.routeLine, lineWidth: 3)
                    .padding(AuraTheme.Spacing.lg)
            }
        }
        .frame(width: ShareCardLayout.mapFieldSize.width,
               height: ShareCardLayout.mapFieldSize.height)
        .clipped()
    }

    // MARK: Readout band (all text lives here, below the map)

    private var readoutBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextRow
            heroRow
                .padding(.top, ShareCardLayout.gapXS)
            if hasElevation {
                ElevationSparkline(elevations: content.elevationSamples,
                                   stroke: AuraTheme.accent,
                                   fill: AuraTheme.accent.opacity(0.18),
                                   lineWidth: 2)
                    .frame(height: ShareCardLayout.sparklineHeight)
                    .padding(.top, ShareCardLayout.gapSM)
            }
            // Bottom-anchors the stats row: absorbs the sparkline's slot when there is
            // no elevation (spec: no dead gap) and the small budget slack when there is.
            Spacer(minLength: ShareCardLayout.gapSM)
            statsRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, ShareCardLayout.bandHorizontalPadding)
        .padding(.top, ShareCardLayout.bandTopPadding)
        .padding(.bottom, ShareCardLayout.bandBottomPadding)
    }

    private var contextRow: some View {
        Text(contextLine)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .tracking(1.5)
            .lineLimit(1)
            .foregroundStyle(scrimText)
    }

    private var heroRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xs) {
            Text(content.distanceValue)
                .font(AuraTheme.Typography.speedHero(ShareCardLayout.heroPointSize))
                .foregroundStyle(AuraTheme.textPrimary)
            Text(content.distanceUnit)
                .font(AuraTheme.Typography.metricCockpit(ShareCardLayout.heroUnitPointSize,
                                                         face: .semibold))
                .foregroundStyle(scrimText)
        }
    }

    private var statsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            statsText
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: AuraTheme.Spacing.sm)
            wordmark
                .fixedSize()
                .layoutPriority(1)
        }
    }

    /// Moving time and climbed as one concatenated run: Saira numerals (the cockpit-numeral
    /// rule), SF Rounded labels.
    private var statsText: Text {
        let valueFont = AuraTheme.Typography.metricCockpit(ShareCardLayout.statsValuePointSize,
                                                           face: .semibold)
        let labelFont = Font.system(size: ShareCardLayout.statsLabelPointSize,
                                    weight: .semibold, design: .rounded)
        return Text(movingValue).font(valueFont).foregroundStyle(AuraTheme.textPrimary)
            + Text(" MIN MOVING · ").font(labelFont).foregroundStyle(scrimText)
            + Text(content.climbedValue).font(valueFont).foregroundStyle(AuraTheme.textPrimary)
            + Text(" \(content.climbedUnit.uppercased()) CLIMBED")
                .font(labelFont).foregroundStyle(scrimText)
    }

    /// `RideStatsFormatter.minutes` returns "<n> min" (e.g. "42 min"); the stats row needs
    /// the bare numeral for the Saira run — its own label supplies "MIN MOVING". Dropping
    /// the formatter's " min" suffix here keeps `ShareCardContent` untouched (spec non-goal).
    private var movingValue: String {
        content.movingTime.hasSuffix(" min")
            ? String(content.movingTime.dropLast(4))
            : content.movingTime
    }

    private var wordmark: some View {
        Text("AURA")
            .font(AuraTheme.Typography.metricCockpit(ShareCardLayout.wordmarkPointSize,
                                                     face: .semibold, relativeTo: .callout))
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
                         labelFont: .system(.subheadline, design: .rounded),
                         labelColor: scrimText)
                StatPair(value: "\(content.climbedValue) \(content.climbedUnit)",
                         label: "climbed", context: .cockpit, alignment: .center,
                         labelFont: .system(.subheadline, design: .rounded),
                         labelColor: scrimText)
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

// MARK: - Preview fixtures

private func previewRide(distanceMeters: Double = 8046, movingSeconds: Double = 2520,
                         gainMeters: Double = 73, elevation: Bool = true,
                         destination: String? = "Millvale", points: Int = 40) -> Ride {
    Ride(kind: .navigate, startedAt: Date(timeIntervalSince1970: 1_782_907_200),
         endedAt: nil,
         track: (0..<points).map { i in
             TrackPoint(coordinate: Coordinate(latitude: 40.44 + Double(i) * 0.001,
                                               longitude: -79.99 + Double(i) * 0.0012),
                        elevation: elevation ? 240 + 30 * sin(Double(i) / 4) : nil,
                        timestamp: Date())
         },
         stats: RideStats(distanceMeters: distanceMeters, movingTimeSeconds: movingSeconds,
                          averageSpeedMetersPerSecond: 5, maxSpeedMetersPerSecond: 9,
                          elevationGainMeters: gainMeters),
         destinationName: destination, routeId: nil, destinationPlaceId: nil)
}

/// A stand-in for an accepted Snapshotter raster: a muted gradient at the exact request
/// geometry (360×240 pt @3x) so the preview exercises the resizable/clipped raster path.
private func previewMapFixture() -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = ShareCardLayout.rasterScale
    return UIGraphicsImageRenderer(size: ShareCardLayout.mapFieldSize, format: format).image { ctx in
        let colors = [UIColor(red: 0.16, green: 0.28, blue: 0.24, alpha: 1).cgColor,
                      UIColor(red: 0.04, green: 0.07, blue: 0.09, alpha: 1).cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors as CFArray, locations: [0, 1]) else { return }
        ctx.cgContext.drawLinearGradient(
            gradient, start: .zero,
            end: CGPoint(x: ShareCardLayout.mapFieldSize.width,
                         y: ShareCardLayout.mapFieldSize.height),
            options: [])
    }
}

#Preview("Map raster") {
    ShareCardView(content: ShareCardContent(ride: previewRide(), units: .imperial),
                  mapImage: previewMapFixture())
}

#Preview("Polyline fallback") {
    ShareCardView(content: ShareCardContent(ride: previewRide(), units: .imperial),
                  mapImage: nil)
}

#Preview("No route") {
    ShareCardView(content: ShareCardContent(
        ride: previewRide(distanceMeters: 5000, movingSeconds: 1200, gainMeters: 20,
                          destination: nil, points: 0),
        units: .imperial), mapImage: nil)
}

#Preview("Route, no elevation") {
    // Exercises the Spacer anchoring: no sparkline, stats row still bottom-anchored.
    ShareCardView(content: ShareCardContent(
        ride: previewRide(distanceMeters: 6400, movingSeconds: 1800, gainMeters: 55,
                          elevation: false, destination: "Downtown", points: 30),
        units: .imperial), mapImage: nil)
}

#Preview("Long destination") {
    // Context line must tail-truncate on one line, never wrap into the hero's budget.
    ShareCardView(content: ShareCardContent(
        ride: previewRide(destination: "The Frank Curto Overlook at Bigelow Boulevard"),
        units: .imperial), mapImage: nil)
}

#Preview("Worst-case stats") {
    // 480 MIN MOVING · 12000 FT CLIMBED — the hand-measured width case the spec covers by
    // preview: the stats run scales (≥0.85) rather than clipping, wordmark holds fixed.
    ShareCardView(content: ShareCardContent(
        ride: previewRide(distanceMeters: 160_934, movingSeconds: 28_800, gainMeters: 3657.6),
        units: .imperial),
                  mapImage: previewMapFixture())
}

#Preview("Metric") {
    ShareCardView(content: ShareCardContent(ride: previewRide(), units: .metric),
                  mapImage: previewMapFixture())
}
