import SwiftUI
import CoreLocation
import AuraCore
import AuraKit

/// The summary's way into replay (spec D1): a Replay pill over the map, and the cover. Applied to
/// `StaticRouteMap` before the summary's own frame/clip/opacity modifiers, so the pill is clipped
/// with the map and fades in with it. The map itself stays inert (ROH-84 taught riders that
/// tapping a map makes it live).
///
/// Everything the cover needs — timeline, band, drawable lines — is built here, once, off the
/// main actor, and passed down; no `View.init` or `body` walks `ride.segments` again.
private struct ReplayEntryModifier: ViewModifier {
    let ride: Ride
    @State private var built: Built?
    @State private var isPresented = false

    struct Built: Sendable {
        var timeline: ReplayTimeline
        var band: ReplayBandContent
        var lines: [[CLLocationCoordinate2D]]
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let built, built.timeline.isReplayable {
                    Button { isPresented = true } label: {
                        Label("Replay", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AuraTheme.accent)
                            .padding(.horizontal, AuraTheme.Spacing.md)
                            .padding(.vertical, AuraTheme.Spacing.sm)
                    }
                    .mapChip(Capsule())
                    .padding(AuraTheme.Spacing.md)
                    .accessibilityLabel("Replay this ride")
                    .accessibilityIdentifier(RideTestID.replayEntry)
                }
            }
            .fullScreenCover(isPresented: $isPresented) {
                if let built {
                    RideReplayView(ride: ride, timeline: built.timeline, band: built.band, lines: built.lines)
                }
            }
            // The build runs detached, so it does not inherit this `.task`'s cancellation; the
            // guard below keeps a superseded build from landing if one ever outlives it. Both
            // shipped presentations — the History sheet's `.id(ride.id)` and the pushed ride-end
            // route — already give this modifier a fresh identity per ride.
            .task(id: ride.id) {
                let ride = ride
                let result = await Task.detached(priority: .userInitiated) {
                    let timeline = ReplayTimeline(segments: ride.segments)
                    let lines = timeline.drawableLines.map { line in
                        line.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    }
                    return Built(timeline: timeline, band: ReplayBandContent(ride: ride, timeline: timeline), lines: lines)
                }.value
                guard !Task.isCancelled else { return }
                built = result
            }
    }
}

extension View {
    /// See `ReplayEntryModifier`.
    func replayEntry(ride: Ride) -> some View {
        modifier(ReplayEntryModifier(ride: ride))
    }
}
