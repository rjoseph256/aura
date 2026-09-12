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
            // Map-specific modifiers (above) return `Self` (still `Map`); `.onCameraChanged` and
            // `.onMapIdle` must stay in that chain — a generic View modifier below (e.g.
            // `.overlay`) would type-erase to `some View` and drop the Map-only API.
            .onCameraChanged { _ in
                if !programmatic, !movedOffFit { movedOffFit = true }
            }
            // The map goes idle after the initial fit lands (the style-load camera changes that
            // arrive first are ignored while `programmatic` is still true) and after every
            // animation completes, so this is where the programmatic window actually closes for
            // `fit()`'s direct assignment (see its comment: an animation on an unloaded map is
            // dropped by the SDK, so `fit()` cannot rely on a `withViewportAnimation` completion).
            .onMapIdle { _ in programmatic = false }
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
        // Direct assignment, not `withViewportAnimation`: the map has not loaded its style yet
        // when this runs from `.onAppear`, and the SDK drops an animation on an unloaded map —
        // its completion then fired before the style-load camera settle arrived, so that settle
        // read as a rider gesture and the recenter control showed at fraction 0 with the marker
        // off-screen. A direct set is what the SDK applies correctly once the map is ready.
        // `programmatic` is cleared by `.onMapIdle` below, not by an animation completion.
        viewport = overview
    }

    /// Reduce Motion snaps (a direct assignment — a snap has no flight to await, so `onMapIdle`
    /// is the only thing that clears `programmatic`, and there's nothing to keep the control
    /// hidden for until then), otherwise flies via `withViewportAnimation` — `RideHUDView
    /// .recenter()`'s rule.
    private func recenter() {
        if reduceMotion {
            programmatic = true
            viewport = overview
            movedOffFit = false
        } else {
            programmatic = true
            withViewportAnimation(.easeOut(duration: 0.4)) {
                viewport = overview
            } completion: { _ in
                programmatic = false
                movedOffFit = false
            }
        }
    }
}
