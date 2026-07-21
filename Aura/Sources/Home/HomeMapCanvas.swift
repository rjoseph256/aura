import SwiftUI
import AuraCore
import AuraKit

/// Swaps Home's backdrop between the frozen idle snapshot and the live map. Idle shows a
/// "tap to explore" affordance; the first tap activates the live map at the same camera. The
/// live→idle edge is INSTANT (no animation) so the live renderer is gone before any route push
/// mounts another map (single-renderer invariant); only idle→live is animated.
struct HomeMapCanvas: View {
    let renderer: TerrainSnapshotRendering
    @Bindable var model: HomeMapModel
    var savedPlaces: [SavedPlace] = []
    var onSelectSaved: (SavedPlace) -> Void = { _ in }
    var flyTo: Coordinate?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HomeBackdrop(renderer: renderer, camera: model.idleCamera, precise: true, placeName: nil)
                .allowsHitTesting(model.phase == .idle)

            if model.phase == .live {
                HomeLiveMap(model: model, savedPlaces: savedPlaces, onSelectSaved: onSelectSaved, flyTo: flyTo)
                    // Animate the APPEARANCE (idle→live) only; removal is instant.
                    .transition(.asymmetric(insertion: reduceMotion ? .identity : .opacity, removal: .identity))
            }

            if model.phase == .idle { tapToExplore }
        }
        // Animate only when going TO live; disappearance is not animated (see removal: .identity).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.phase == .live)
    }

    private var tapToExplore: some View {
        Button { withAnimation { model.phase = HomeMapReducer.next(model.phase, on: .activate) } } label: {
            Label("Tap to explore the map", systemImage: "hand.tap")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityIdentifier("home.tapToExplore")
    }
}
