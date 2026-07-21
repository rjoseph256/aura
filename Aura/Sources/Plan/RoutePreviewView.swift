import SwiftUI
import MapboxMaps
import Turf
import AuraCore
import AuraKit

// MARK: - SaveMoment

/// Transient state shown under the route-preview header after the save star
/// is tapped: the "Saved" + Set-as-Home offer, then its confirmation.
enum SaveMoment: Equatable {
    case saved(SavedPlace)          // "Saved" + Set as Home offer
    case homeSet(demoted: Bool)     // confirmation after taking the offer
}

// MARK: - RoutePreviewView

struct RoutePreviewView: View {
    let destination: Place

    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location
    @Environment(SavedPlacesStore.self) private var savedPlaces
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let provider: any AuraCore.RoutingProvider = MapboxRoutingProvider()

    // MARK: State

    private enum Phase { case loading, loaded, empty, failed }

    @State private var routes: [Route] = []
    @State private var selected: Route?
    @State private var phase: Phase = .loading
    @State private var viewport: Viewport = .styleDefault
    /// Live camera for the +/- zoom pill (ROH-57). Written every frame by `.onCameraChanged`,
    /// read only at tap time, so it never re-renders this view.
    @State private var cameraBox = MapZoomCameraBox()
    @State private var saveMoment: SaveMoment?
    @State private var saveMomentDismiss: Task<Void, Never>?
    @State private var showFullAlert = false

    // MARK: Body

    var body: some View {
        ZStack(alignment: .bottom) {
            AuraTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top ~55 %: map pane
                mapPane
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .top)

                // Bottom ~45 %: route options panel
                bottomPanel
                    .frame(maxWidth: .infinity)
            }
        }
        // The map ignores the safe area on its own (see mapPane); the VStack respects
        // it, so the back button lands below the status bar without a magic inset.
        .task { await loadRoutes() }
        .onChange(of: selected) { _, newRoute in
            if let route = newRoute {
                fitCamera(to: route, animate: !reduceMotion)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled(true)
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewHeader(
                destinationName: destination.name,
                isSaved: isSaved,
                saveMoment: saveMoment,
                onToggleSaved: toggleSaved
            ) { saved in
                let demoted = savedPlaces.setHome(id: saved.id)
                setSaveMoment(.homeSet(demoted: demoted))
            }

            // Route options / skeleton / error
            Group {
                switch phase {
                case .loading:
                    skeletonRows
                case .loaded:
                    routeRows
                case .empty:
                    emptyMessage
                case .failed:
                    failedMessage
                }
            }

            Spacer(minLength: 12)

            // CTA
            startButton
                .padding(.horizontal, AuraTheme.Spacing.xxl)
                .padding(.bottom, AuraTheme.Spacing.xxl)
        }
        .background(AuraTheme.background)
        .alert("Saved places is full. Remove one to save another.",
               isPresented: $showFullAlert) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Save star

    private var isSaved: Bool { savedPlaces.isSaved(destination) }

    private func toggleSaved() {
        if savedPlaces.savedPlace(for: destination) != nil {
            savedPlaces.unsave(destination)   // no moment on unsave
            setSaveMoment(nil)
            return
        }
        switch savedPlaces.save(destination, subtitle: destination.subtitle) {
        case .full: showFullAlert = true
        case let .saved(saved): setSaveMoment(.saved(saved))
        }
    }

    /// House convention: animate the moment change unless Reduce Motion is on.
    private func setSaveMoment(_ moment: SaveMoment?) {
        saveMomentDismiss?.cancel()
        withMomentAnimation { saveMoment = moment }
        guard moment != nil else { return }
        saveMomentDismiss = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withMomentAnimation { saveMoment = nil }
        }
    }

    private func withMomentAnimation(_ change: () -> Void) {
        guard !reduceMotion else { return change() }
        withAnimation(.easeOut(duration: 0.2), change)
    }

    // MARK: Route rows

    /// One vertical scale shared across every option's elevation sparkline, so a flat
    /// route and a hilly one compare honestly at a glance. nil when no option has a profile.
    private var sharedElevationRange: ClosedRange<Double>? {
        let all = routes.flatMap(\.elevationProfile)
        guard let lo = all.min(), let hi = all.max() else { return nil }
        return lo...hi
    }

    private var routeRows: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            ForEach(routes) { route in
                RouteOptionRow(
                    route: route,
                    units: settings.units,
                    isSelected: selected?.id == route.id,
                    reduceMotion: reduceMotion,
                    elevationRange: sharedElevationRange
                ) {
                    selected = route
                }
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    // MARK: Skeleton rows

    private var skeletonRows: some View {
        VStack(spacing: 0) {
            VStack(spacing: AuraTheme.Spacing.sm) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonRow(reduceMotion: reduceMotion)
                }
            }
            .padding(.horizontal, AuraTheme.Spacing.xxl)

            // Calm loading label below skeletons
            Text("Finding bike routes…")
                .font(.footnote)
                .foregroundStyle(AuraTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, AuraTheme.Spacing.sm)
                .padding(.horizontal, AuraTheme.Spacing.xxl)
        }
    }

    // MARK: Empty / failed states

    private var emptyMessage: some View {
        statusMessage("No bike route found to here — try another destination.")
    }

    private var failedMessage: some View {
        statusMessage("Couldn't fetch routes right now. Check your connection and try again.")
    }

    private func statusMessage(_ text: String) -> some View {
        VStack(spacing: AuraTheme.Spacing.lg) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AuraTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AuraTheme.Spacing.xxl)
            backButton
        }
        .frame(maxWidth: .infinity)
    }

    private var backButton: some View {
        Button {
            router.pop()
        } label: {
            Text("Back")
                .font(.headline)
                .foregroundStyle(AuraTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(AuraTheme.surface, in: Capsule())
                .padding(.horizontal, AuraTheme.Spacing.xxl)
        }
        .buttonStyle(.plain)
    }

    // MARK: Start CTA

    private var startButton: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            Button("Start RIDE") {
                if let selected {
                    router.push(.navigate(route: selected, destination: destination))
                }
            }
            .buttonStyle(.ctaPrimary)
            .disabled(selected == nil)

            Button("Ride together") {
                if let selected {
                    router.startGroupRide(.create(selected))
                }
            }
            .buttonStyle(.ctaSecondary)
            .disabled(selected == nil)
        }
        .animation(.easeOut(duration: 0.18), value: selected?.id)
    }

    // MARK: Data loading

    private func loadRoutes() async {
        phase = .loading
        let origin = await location.current()
        let request = RouteRequest(origin: origin, destination: destination.coordinate)
        do {
            let fetched = try await provider.routes(for: request)
            routes = fetched
            phase = fetched.isEmpty ? .empty : .loaded
            selected = fetched.first
            if let first = fetched.first {
                fitCamera(to: first, animate: false)
            }
        } catch {
            phase = .failed
        }
    }

    // MARK: Camera helpers

    private func fitCamera(to route: Route, animate: Bool) {
        guard route.geometry.count > 1 else { return }
        let coords = route.geometry.map {
            LocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        let lineString = LineString(coords)
        let targetViewport = Viewport.overview(
            geometry: lineString,
            geometryPadding: .init(top: 48, leading: 24, bottom: 48, trailing: 24),
            maxZoom: 16
        )
        if animate {
            withViewportAnimation(.easeOut(duration: 0.45)) {
                viewport = targetViewport
            }
        } else {
            viewport = targetViewport
        }
    }
}

// MARK: - Map pane (extension keeps the main type body under the length limit)

private extension RoutePreviewView {
    var mapPane: some View {
        ZStack(alignment: .topLeading) {
            Map(viewport: $viewport) {
                if let route = selected, route.geometry.count > 1 {
                    PolylineAnnotationGroup {
                        PolylineAnnotation(
                            lineCoordinates: route.geometry.map {
                                CLLocationCoordinate2D(latitude: $0.latitude,
                                                       longitude: $0.longitude)
                            }
                        )
                        .lineColor(StyleColor(AuraTheme.routeUIColor))
                        .lineWidth(5)
                    }
                }
            }
            .mapStyle(settings.mapStyle.mapboxStyle)
            // Mirror the live camera into the zoom box. Must precede `.ignoresSafeArea()`
            // (a type-erasing View modifier) to stay in the Map-only modifier chain.
            .onCameraChanged { ctx in
                cameraBox.zoom = ctx.cameraState.zoom
                cameraBox.center = ctx.cameraState.center
                cameraBox.bearing = ctx.cameraState.bearing
                cameraBox.pitch = ctx.cameraState.pitch
            }
            .ignoresSafeArea()

            // Back chevron — HUDControlButton carries the 44pt hit area and the
            // Reduce Transparency fallback.
            Button {
                router.pop()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(HUDControlButton())
            .accessibilityLabel("Back")
            .padding(.top, AuraTheme.Spacing.sm)   // sits in the safe area
            .padding(.leading, AuraTheme.Spacing.lg)
        }
        // +/- zoom pill (ROH-57), top-trailing so it mirrors the back chevron and clears the
        // route-options panel seam below. `.standard` sizing — the rider is stationary here.
        .overlay(alignment: .topTrailing) {
            MapZoomControl(metrics: .standard,
                           onZoomIn: { zoomStep(.zoomIn) },
                           onZoomOut: { zoomStep(.zoomOut) })
                .padding(.top, AuraTheme.Spacing.sm)
                .padding(.trailing, AuraTheme.Spacing.lg)
        }
    }

    /// Steps the preview map zoom for a +/- tap (ROH-57). The preview never follows a puck, so
    /// this always zooms around the current center. Snaps under Reduce Motion, otherwise a quick
    /// 0.3s flick. No-op until the first camera frame gives us a finite center + zoom.
    func zoomStep(_ direction: MapZoomStep.Direction) {
        guard let center = cameraBox.center, cameraBox.zoom.isFinite else { return }
        let target = MapZoomStep.stepped(from: cameraBox.zoom, direction)
        let next = Viewport.camera(center: center, zoom: target,
                                   bearing: cameraBox.bearing, pitch: cameraBox.pitch)
        if reduceMotion {
            viewport = next
        } else {
            withViewportAnimation(.easeOut(duration: 0.3)) { viewport = next }
        }
    }
}

// MARK: - RouteOptionRow

private struct RouteOptionRow: View {
    let route: Route
    let units: DistanceUnits
    let isSelected: Bool
    let reduceMotion: Bool
    /// Shared elevation scale across all options (nil → self-scale).
    var elevationRange: ClosedRange<Double>?
    let onTap: () -> Void

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    private var label: String {
        switch route.profile {
        case .mostPaths: return "Most paths"
        case .fastest:   return "Fastest"
        case .flattest:  return "Flattest"
        }
    }

    private var glyph: String {
        switch route.profile {
        case .mostPaths: return "leaf.fill"
        case .fastest:   return "bolt.fill"
        case .flattest:  return "chart.line.flattrend.xyaxis"
        }
    }

    private var metricText: String {
        var text = "\(fmt.distanceValue(route.distanceMeters)) \(fmt.distanceUnit) · \(fmt.minutes(route.estimatedDurationSeconds))"
        if route.elevationGainMeters > 0 {
            text += " · \(fmt.elevationValue(route.elevationGainMeters)) \(fmt.elevationUnit)↑"
        }
        return text
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AuraTheme.Spacing.lg) {
                Image(systemName: glyph)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? AuraTheme.onAccent : AuraTheme.textPrimary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.headline)
                        .foregroundStyle(isSelected ? AuraTheme.onAccent : AuraTheme.textPrimary)
                    Text(metricText)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? AuraTheme.onAccent : AuraTheme.textSecondary)
                }

                Spacer(minLength: AuraTheme.Spacing.sm)

                // Elevation profile — lets the rider compare hilliness across options.
                if route.elevationProfile.count > 1 {
                    ElevationSparkline(
                        elevations: route.elevationProfile,
                        stroke: isSelected ? AuraTheme.onAccent : AuraTheme.accent,
                        fill: isSelected ? AuraTheme.onAccent.opacity(0.16) : AuraTheme.accent.opacity(0.16),
                        range: elevationRange
                    )
                    .frame(width: 54, height: 26)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AuraTheme.onAccent)
                }
            }
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .padding(.vertical, AuraTheme.Spacing.lg)
            .frame(minHeight: 56)
            .background(
                isSelected
                    ? AnyShapeStyle(AuraTheme.accent)
                    : AnyShapeStyle(AuraTheme.surface),
                in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSelected)
    }
}

// MARK: - SkeletonRow

private struct SkeletonRow: View {
    let reduceMotion: Bool
    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.lg) {
            RoundedRectangle(cornerRadius: AuraTheme.Radius.sm, style: .continuous)
                .fill(AuraTheme.surface)
                .frame(width: 24, height: 20)
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
                RoundedRectangle(cornerRadius: AuraTheme.Radius.xs, style: .continuous)
                    .fill(AuraTheme.surface)
                    .frame(width: 100, height: 14)
                RoundedRectangle(cornerRadius: AuraTheme.Radius.xs, style: .continuous)
                    .fill(AuraTheme.surface)
                    .frame(width: 140, height: 11)
            }
            Spacer()
        }
        .padding(.horizontal, AuraTheme.Spacing.lg)
        .padding(.vertical, AuraTheme.Spacing.lg)
        .frame(minHeight: 56)
        .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
        .opacity(reduceMotion ? 1.0 : (pulse ? 0.45 : 0.9))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            ) {
                pulse = true
            }
        }
    }
}
