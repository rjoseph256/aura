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
    var flyTo: Coordinate?

    @Environment(LocationService.self) private var location
    @State private var viewport: Viewport
    /// True while OUR animation (recenter/flyTo) drives the camera, so its `onCameraChanged`
    /// callbacks don't get counted as a user pan (which would re-show the recenter button).
    @State private var programmatic = false

    init(model: HomeMapModel, savedPlaces: [SavedPlace] = [],
         onSelectSaved: @escaping (SavedPlace) -> Void = { _ in }, flyTo: Coordinate? = nil) {
        self.model = model
        self.savedPlaces = savedPlaces
        self.onSelectSaved = onSelectSaved
        self.flyTo = flyTo
        _viewport = State(initialValue: .camera(
            center: CLLocationCoordinate2D(latitude: model.liveCamera.center.latitude,
                                           longitude: model.liveCamera.center.longitude),
            zoom: model.liveCamera.zoom))
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
        }
        .mapStyle(AuraKit.MapStyle.auraTerrain.mapboxStyle)
        .gestureOptions(GestureOptions(rotateEnabled: false, pitchEnabled: false))
        // Enforce zoom bounds on the MAP (not just clamp state) so a pinch can't exceed them.
        .cameraBounds(CameraBoundsOptions(maxZoom: HomeMapCamera.maxZoom, minZoom: HomeMapCamera.minZoom))
        .ignoresSafeArea()
        .onCameraChanged { ctx in
            // Store in the @Observable model, never in @State (MapboxMaps guidance: high-freq).
            model.liveCamera = HomeMapCamera(
                center: Coordinate(latitude: ctx.cameraState.center.latitude,
                                   longitude: ctx.cameraState.center.longitude),
                zoom: Double(ctx.cameraState.zoom)).clampedZoom()
            if !programmatic { model.movedOffRider = true } // user pan only
        }
        // External camera change (post-ride reset) must move an already-mounted map.
        .onChange(of: model.liveCamera) { _, cam in
            guard !model.movedOffRider else { return } // don't fight an active pan
            animate(to: cam)
        }
        .onChange(of: flyTo) { _, target in
            if let target {
                animate(to: HomeMapCamera(center: target, zoom: HomeMapCamera.defaultZoom))
                model.movedOffRider = true
            }
        }
        .overlay(alignment: .trailing) {
            if model.movedOffRider { recenterButton.padding(.trailing, AuraTheme.Spacing.lg) }
        }
    }

    private func animate(to cam: HomeMapCamera) {
        programmatic = true
        withViewportAnimation(.easeOut(duration: 0.4)) {
            viewport = .camera(center: CLLocationCoordinate2D(latitude: cam.center.latitude,
                                                              longitude: cam.center.longitude),
                               zoom: cam.zoom)
        } completion: { _ in programmatic = false }
    }

    private var recenterButton: some View {
        GlassCircleButton {
            Task {
                let rider = await location.current()
                animate(to: HomeMapCamera(center: rider, zoom: HomeMapCamera.defaultZoom))
                model.movedOffRider = false
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

#Preview {
    let model = HomeMapModel(initial: HomeMapCamera(
        center: Coordinate(latitude: 40.4406, longitude: -79.9959), zoom: HomeMapCamera.defaultZoom))
    let savedPlace = SavedPlace(name: "Home", subtitle: "123 Main St",
                                coordinate: Coordinate(latitude: 40.4416, longitude: -79.9969),
                                category: .custom, kind: .home, savedAt: Date())
    return HomeLiveMap(model: model, savedPlaces: [savedPlace])
        .environment(LocationService())
}
