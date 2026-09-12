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
    /// True once a real (non-programmatic) camera change has arrived — the `HomeLiveMap` idiom.
    /// MapboxMaps 11.28 never writes `viewport` back to `.idle` after a gesture or the initial
    /// fit, so `viewport.isIdle` alone never flips and the recenter control never showed. Written
    /// once per gesture, never per frame.
    @State private var movedOffFit = false
    /// True while OUR animation (the initial fit or recenter) drives the camera, so its
    /// `onCameraChanged` callback isn't counted as a rider gesture.
    @State private var programmatic = false

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
            // Map-specific modifier (above) returns `Self` (still `Map`); `.onCameraChanged` must
            // stay in that chain — a generic View modifier below (e.g. `.overlay`) would
            // type-erase to `some View` and drop the Map-only API.
            .onCameraChanged { _ in
                if !programmatic, !movedOffFit { movedOffFit = true }
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
                        .padding(.leading, AuraTheme.Spacing.md)
                        .padding(.bottom, 48)
                        .accessibilityHidden(true)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // Shown once `movedOffFit` sees a real (non-programmatic) camera change — MapboxMaps
            // 11.28 never writes `viewport` back to `.idle` after a gesture, so `viewport.isIdle`
            // is kept only as a fallback (belt-and-braces).
            if movedOffFit || viewport.isIdle {
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
                  geometryPadding: .init(top: 24, leading: 24, bottom: 56, trailing: 24),
                  maxZoom: 16)
    }

    private func fit() {
        guard lines.flatMap({ $0 }).count > 1 else { return }
        programmatic = true
        // Zero-duration `.easeOut` (not a plain assignment) so this still lands through the
        // viewport-animation completion, which clears `programmatic`. NOTE: 0.01, not 0 — could
        // not confirm from the SDK source alone whether a 0-duration animation invokes its
        // completion; 0.01 guarantees the animator actually runs. See fixwave report.
        withViewportAnimation(.easeOut(duration: 0.01)) {
            viewport = overview
        } completion: { _ in
            programmatic = false
        }
    }

    /// Reduce Motion snaps (zero-duration animation), otherwise flies — `RideHUDView.recenter()`'s
    /// rule. Both paths go through `withViewportAnimation` (rather than a plain assignment for the
    /// snap case) so `programmatic`/`movedOffFit` are only ever cleared from the completion.
    private func recenter() {
        programmatic = true
        let duration = reduceMotion ? 0.01 : 0.4
        withViewportAnimation(.easeOut(duration: duration)) {
            viewport = overview
        } completion: { _ in
            programmatic = false
            movedOffFit = false
        }
    }
}
