import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// Home's live, movable map: pan + pinch-zoom only (no rotate/pitch), authored Aura terrain
/// style, the rider puck, and Saved pins. Mounted only in `.live`.
struct HomeLiveMap: View {
    @Bindable var model: HomeMapModel
    var savedPlaces: [SavedPlace] = []
    var onSelectSaved: (SavedPlace) -> Void = { _ in }
    @Binding var flyTo: Coordinate?
    /// The picked search destination, if any — rendered as a persistent dropped pin (distinct
    /// from the star `SavedPinView`) so the rider can see where the fly-to landed. Unlike
    /// `flyTo`, this is NOT consumed after the animation: it stays until `HomeView` clears it
    /// (ride completed / cold launch).
    var focusedPlace: Place?
    /// Height of the dashboard sheet's peek (its visible overlap at the bottom of the screen),
    /// so every camera this map frames insets its bottom padding by that much — otherwise a
    /// centered rider/target sits low, behind/near the sheet, instead of in the visible area
    /// above it.
    var bottomInset: CGFloat = 0

    @Environment(LocationService.self) private var location
    @State private var viewport: Viewport
    /// True while OUR animation (recenter/flyTo) drives the camera, so its `onCameraChanged`
    /// callbacks don't get counted as a user pan (which would re-show the recenter button).
    @State private var programmatic = false
    /// True when `init` framed the viewport directly on `flyTo` (mount-with-target). Lets the
    /// first `.onChange(of: flyTo, initial: true)` firing just consume the target instead of
    /// re-animating to where the map already is.
    @State private var didSeedFromFlyTo: Bool

    init(model: HomeMapModel, savedPlaces: [SavedPlace] = [],
         onSelectSaved: @escaping (SavedPlace) -> Void = { _ in },
         flyTo: Binding<Coordinate?> = .constant(nil),
         focusedPlace: Place? = nil, bottomInset: CGFloat = 0) {
        self.model = model
        self.savedPlaces = savedPlaces
        self.onSelectSaved = onSelectSaved
        _flyTo = flyTo
        self.focusedPlace = focusedPlace
        self.bottomInset = bottomInset
        // Seed from the fly-to target when mounting WITH one already set (search/saved picked
        // before the map activated) so the map opens framed on the target deterministically —
        // not on the rider, which `model.liveCamera` would otherwise seed. Otherwise seed from
        // the rider camera as before.
        let seedCamera: HomeMapCamera
        if let target = flyTo.wrappedValue {
            seedCamera = HomeMapCamera(center: target, zoom: HomeMapCamera.defaultZoom)
            _didSeedFromFlyTo = State(initialValue: true)
        } else {
            seedCamera = model.liveCamera
            _didSeedFromFlyTo = State(initialValue: false)
        }
        _viewport = State(initialValue: .camera(
            center: CLLocationCoordinate2D(latitude: seedCamera.center.latitude,
                                           longitude: seedCamera.center.longitude),
            zoom: seedCamera.zoom).padding(.bottom, bottomInset))
    }

    var body: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            ForEvery(savedPlaces, id: \.id) { saved in
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                    latitude: saved.place.coordinate.latitude, longitude: saved.place.coordinate.longitude)) {
                    SavedPinView(name: saved.name) { onSelectSaved(saved) }
                }
                .allowOverlapWithPuck(true)
            }
            // Suppress the dropped pin when the focused place is already a saved place — the
            // star `SavedPinView` above already marks that location, so both would otherwise
            // stack a mappin and a star at the same coordinate.
            if let focusedPlace,
               !savedPlaces.contains(where: { $0.place.coordinate == focusedPlace.coordinate }) {
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                    latitude: focusedPlace.coordinate.latitude, longitude: focusedPlace.coordinate.longitude)) {
                    DestinationPinView(name: focusedPlace.name)
                }
                .allowOverlapWithPuck(true)
            }
        }
        .mapStyle(AuraKit.MapStyle.auraTerrain.mapboxStyle)
        .gestureOptions(GestureOptions(rotateEnabled: false, pitchEnabled: false))
        // Enforce zoom bounds on the MAP (not just clamp state) so a pinch can't exceed them.
        .cameraBounds(CameraBoundsOptions(maxZoom: HomeMapCamera.maxZoom, minZoom: HomeMapCamera.minZoom))
        // Map-specific modifiers (above) return `Self` (still `Map`); `.onCameraChanged` must
        // stay in that chain — a generic View modifier (e.g. `.ignoresSafeArea()`) before it
        // would type-erase to `some View` and drop the Map-only API.
        .onCameraChanged { ctx in
            // Store in the @Observable model, never in @State (MapboxMaps guidance: high-freq).
            model.liveCamera = HomeMapCamera(
                center: Coordinate(latitude: ctx.cameraState.center.latitude,
                                   longitude: ctx.cameraState.center.longitude),
                zoom: Double(ctx.cameraState.zoom)).clampedZoom()
            if !programmatic { model.movedOffRider = true } // user pan only
        }
        .ignoresSafeArea()
        // External camera change (post-ride reset) must move an already-mounted map.
        .onChange(of: model.liveCamera) { _, cam in
            // Ignore both an active user pan AND frames from OUR OWN in-flight animation —
            // `onCameraChanged` writes `liveCamera` on every frame regardless of `programmatic`,
            // so without the `!programmatic` guard each mid-flight frame would re-arm a fresh
            // animation toward the current position and the camera would never settle.
            guard !programmatic, !model.movedOffRider else { return }
            animate(to: cam)
        }
        // `initial: true` so a mount-with-target (search/saved picked before the map was live)
        // is handled on the very first evaluation, not just later changes. `flyTo` is a
        // consumable command: it is always reset to `nil` after being acted on, so re-picking
        // the same coordinate (nil → coordinate again) re-fires this.
        .onChange(of: flyTo, initial: true) { _, target in
            guard let target else { return }
            if didSeedFromFlyTo {
                // `init` already framed the viewport on this target — nothing to animate.
                didSeedFromFlyTo = false
            } else {
                animate(to: HomeMapCamera(center: target, zoom: HomeMapCamera.defaultZoom))
            }
            model.movedOffRider = true
            flyTo = nil // consume
        }
        .overlay(alignment: .trailing) {
            if model.movedOffRider { recenterButton.padding(.trailing, AuraTheme.Spacing.lg) }
        }
    }

    /// - Parameter onComplete: run once the animation finishes, AFTER `programmatic` is cleared.
    ///   Used by recenter to hide the button only when the fly-to-rider actually lands, rather
    ///   than instantly while the camera is still mid-flight.
    private func animate(to cam: HomeMapCamera, onComplete: (() -> Void)? = nil) {
        programmatic = true
        withViewportAnimation(.easeOut(duration: 0.4)) {
            viewport = .camera(center: CLLocationCoordinate2D(latitude: cam.center.latitude,
                                                              longitude: cam.center.longitude),
                               zoom: cam.zoom).padding(.bottom, bottomInset)
        } completion: { _ in
            programmatic = false
            onComplete?()
        }
    }

    private var recenterButton: some View {
        GlassCircleButton {
            Task {
                let rider = await location.current()
                animate(to: HomeMapCamera(center: rider, zoom: HomeMapCamera.defaultZoom)) {
                    model.movedOffRider = false
                }
            }
        } label: { Image(systemName: "location.fill") }
        .accessibilityLabel("Recenter on me")
        .accessibilityIdentifier("home.recenter")
    }
}

/// A small labeled pin for a Saved place. Modeled on GemPinView/PeerDotView in Aura/Sources/Ride/.
struct SavedPinView: View {
    let name: String
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Image(systemName: "star.fill").font(.callout).foregroundStyle(AuraTheme.accent)
                .padding(6).background(AuraTheme.surface, in: Circle())
        }
        .accessibilityLabel("Saved place: \(name)")
    }
}

/// The dropped pin for a search-picked destination — distinct from the star `SavedPinView` so
/// the rider can tell a fly-to target apart from an already-saved place. Not tappable: it is a
/// marker, not an entry point (unlike `SavedPinView`, which opens the place preview).
struct DestinationPinView: View {
    let name: String
    var body: some View {
        Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(AuraTheme.accent)
            .background(AuraTheme.surface, in: Circle())
            .accessibilityLabel("Destination: \(name)")
    }
}

#Preview {
    let model = HomeMapModel(initial: HomeMapCamera(
        center: Coordinate(latitude: 40.4406, longitude: -79.9959), zoom: HomeMapCamera.defaultZoom))
    let savedPlace = SavedPlace(name: "Home", subtitle: "123 Main St",
                                coordinate: Coordinate(latitude: 40.4416, longitude: -79.9969),
                                category: .custom, kind: .home, savedAt: Date())
    return HomeLiveMap(model: model, savedPlaces: [savedPlace])
        .environment(LocationService())
}
