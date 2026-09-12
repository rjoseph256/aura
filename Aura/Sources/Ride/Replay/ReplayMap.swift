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
    /// The binding did not go idle on the simulator pass (the SDK's touch-to-idle path is
    /// present but was not observed), so `viewport.isIdle` alone never flipped and the recenter
    /// control never showed; this state no longer depends on it. Written once per gesture,
    /// never per frame.
    @State private var movedOffFit = false
    /// True while OUR animation (the initial fit or recenter) drives the camera, so its
    /// `onCameraChanged` callback isn't counted as a rider gesture.
    @State private var programmatic = false
    /// True once the fit's own camera (not the style-load default) has actually arrived — guards
    /// `.onMapIdle` clearing `programmatic` on the style-load idle that precedes the fit.
    @State private var fitApplied = false

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
            .onCameraChanged { ctx in
                // The world-default camera is ~zoom 0; any ride overview is far above 3, so this
                // only trips once the fit's own camera (not the style-load default) has arrived.
                if programmatic, ctx.cameraState.zoom > 3 { fitApplied = true }
                // Also write `.idle` here: the binding did not go idle on the simulator pass
                // (that's the whole reason `movedOffFit` exists, and the map no longer depends
                // on the SDK's own touch-to-idle path), so without this a pinch leaves
                // `viewport` holding the SAME `.overview` `fit()` already stored, and
                // `recenter()`'s later `viewport = overview` is then a no-op SwiftUI value — no
                // state change, no animation, no completion, so `programmatic`/`movedOffFit`
                // never clear and the control neither moves the camera nor hides. Writing
                // `.idle` restores the invariant: the rider's camera position is left alone
                // (`.idle` doesn't move it), but the NEXT `.overview` write is guaranteed to be
                // a real change again.
                if !programmatic, !movedOffFit { movedOffFit = true; viewport = .idle }
            }
            // The map goes idle after the initial fit lands (the style-load camera changes that
            // arrive first are ignored while `programmatic` is still true) and after every
            // animation completes, so this is where the programmatic window actually closes for
            // `fit()`'s direct assignment (see its comment: an animation on an unloaded map is
            // dropped by the SDK, so `fit()` cannot rely on a `withViewportAnimation` completion).
            // Gated on `fitApplied` so the style-load idle that precedes the fit's own camera
            // can't clear `programmatic` early (v2.4: low-probability cold-load race).
            .onMapIdle { _ in if fitApplied { programmatic = false } }
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
            // Shown once `movedOffFit` sees a real (non-programmatic) camera change. The binding
            // did not go idle on its own on the simulator pass, so `onCameraChanged`
            // above writes it explicitly — that also keeps `recenter()`'s later `.overview`
            // write a real state change (not a no-op equal to what's already there), so tapping
            // this control both moves the camera and clears the flags that hide it again.
            // `viewport.isIdle` is kept only as a fallback (belt-and-braces).
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
            fitApplied = true   // the map is already framed; no fit-arrival to wait for
            viewport = overview
            movedOffFit = false
        } else {
            programmatic = true
            fitApplied = true   // the map is already framed; no fit-arrival to wait for
            withViewportAnimation(.easeOut(duration: 0.4)) {
                viewport = overview
            } completion: { _ in
                programmatic = false
                movedOffFit = false
            }
        }
    }
}
