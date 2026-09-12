import SwiftUI
import MapboxMaps
import Turf
import AuraCore
import AuraKit

/// The replay's map (spec D8): the cased route as a style source under a line layer, and the
/// rider as a `MapViewAnnotation`, inside one `TimelineView` that runs only while playing. The
/// structure `NavigateHUDView` runs at 30 Hz: the SDK re-uploads GeoJSON only when `data`
/// differs, so a frame that moves the marker touches nothing else.
///
/// `lines` is built once by the entry modifier from `ReplayTimeline.drawableLines`.
/// `context.date` is used for RENDERING ONLY; every mutation takes `Date()`.
struct ReplayMap: View {
    let timeline: ReplayTimeline
    let lines: [[CLLocationCoordinate2D]]
    let playback: ReplayPlayback

    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewport: Viewport = .styleDefault

    private static let sourceID = "aura-replay-route"

    var body: some View {
        TimelineView(.animation(paused: !playback.isPlaying)) { context in
            let sample = timeline.sample(at: playback.fraction(at: context.date))
            Map(viewport: $viewport) {
                if !lines.isEmpty {
                    routeSource
                    LineLayer(id: "aura-replay-route-line", source: Self.sourceID)
                        .lineColor(StyleColor(AuraTheme.routeUIColor))
                        .lineWidth(AuraTheme.RouteStroke.width)
                        .lineBorderColor(StyleColor(AuraTheme.routeCasingUIColor))
                        .lineBorderWidth(AuraTheme.RouteStroke.casingWidth)
                        .lineCap(.round)
                        .lineJoin(.round)
                }
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                    latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude)) {
                    ReplayMarkerView(sample: sample, reduceMotion: reduceMotion)
                }
                .allowOverlapWithPuck(true)
            }
            .gestureOptions(gestureOptions)
            .ornamentOptions(ornamentOptions)
            .mapStyle(settings.mapStyle.mapboxStyle)
            .overlay(alignment: .bottomLeading) {
                if case let .hold(kind, seconds) = sample.phase {
                    Text(ReplayReadout.holdLabel(kind: kind, seconds: seconds))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .padding(.horizontal, AuraTheme.Spacing.md)
                        .padding(.vertical, AuraTheme.Spacing.sm)
                        .mapChip(Capsule())
                        .padding(AuraTheme.Spacing.md)
                        .accessibilityHidden(true)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // `viewport.isIdle` is the SDK's write-back when the viewport manager goes idle,
            // which a rider gesture causes; recenter's `.overview` clears it. A failed initial
            // fit would also show it (spec §10) — accepted.
            if viewport.isIdle {
                Button(action: recenter) { Image(systemName: "location.fill") }
                    .buttonStyle(.hudControl(active: true))
                    .accessibilityLabel("Recenter map")
                    .padding(AuraTheme.Spacing.md)
            }
        }
        .onAppear(perform: fit)
    }

    private var routeSource: GeoJSONSource {
        var source = GeoJSONSource(id: Self.sourceID)
        source.data = .feature(Feature(geometry: MultiLineString(lines)))
        return source
    }

    private var gestureOptions: GestureOptions {
        var options = GestureOptions()
        options.rotateEnabled = false
        options.pitchEnabled = false
        return options
    }

    private var ornamentOptions: OrnamentOptions {
        var options = OrnamentOptions()
        options.scaleBar.visibility = .hidden
        options.compass.visibility = .hidden
        return options
    }

    private var overview: Viewport {
        .overview(geometry: LineString(lines.flatMap { $0 }),
                  geometryPadding: .init(top: 24, leading: 24, bottom: 24, trailing: 24),
                  maxZoom: 16)
    }

    private func fit() {
        guard lines.flatMap({ $0 }).count > 1 else { return }
        viewport = overview
    }

    /// Snaps under Reduce Motion, flies otherwise — `RideHUDView.recenter()`'s rule.
    private func recenter() {
        if reduceMotion {
            viewport = overview
        } else {
            withViewportAnimation(.easeOut(duration: 0.4)) { viewport = overview }
        }
    }
}
