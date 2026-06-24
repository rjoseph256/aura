import SwiftUI
import MapboxMaps
import Turf
import AuraCore
import AuraKit

// MARK: - RoutePreviewView

struct RoutePreviewView: View {
    let destination: Place

    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let provider: any AuraCore.RoutingProvider = MapboxRoutingProvider()

    // MARK: State

    private enum Phase { case loading, loaded, empty, failed }

    @State private var routes: [Route] = []
    @State private var selected: Route?
    @State private var phase: Phase = .loading
    @State private var viewport: Viewport = .styleDefault

    // MARK: Body

    var body: some View {
        ZStack(alignment: .bottom) {
            AuraTheme.bg.ignoresSafeArea()

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
        .ignoresSafeArea(edges: .top)
        .task { await loadRoutes() }
        .onChange(of: selected) { _, newRoute in
            if let route = newRoute {
                fitCamera(to: route, animate: !reduceMotion)
            }
        }
    }

    // MARK: Map pane

    private var mapPane: some View {
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
                        .lineColor(StyleColor(UIColor(red: 43 / 255,
                                                      green: 224 / 255,
                                                      blue: 138 / 255,
                                                      alpha: 1)))
                        .lineWidth(5)
                    }
                }
            }
            .mapStyle(.dark)
            .ignoresSafeArea()

            // Back chevron — ≥44pt hit area
            Button {
                router.screen = .plan
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AuraTheme.text)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 56)   // below status bar
            .padding(.leading, 16)
        }
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name)
                    .font(.title3.bold())
                    .foregroundStyle(AuraTheme.text)
                    .lineLimit(1)
                Text("Choose a route")
                    .font(.subheadline)
                    .foregroundStyle(AuraTheme.muted)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

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
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .background(AuraTheme.bg)
    }

    // MARK: Route rows

    private var routeRows: some View {
        VStack(spacing: 10) {
            ForEach(routes) { route in
                RouteOptionRow(
                    route: route,
                    isSelected: selected?.id == route.id,
                    reduceMotion: reduceMotion
                ) {
                    selected = route
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: Skeleton rows

    private var skeletonRows: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonRow(reduceMotion: reduceMotion)
                }
            }
            .padding(.horizontal, 24)

            // Calm loading label below skeletons
            Text("Finding bike routes…")
                .font(.footnote)
                .foregroundStyle(AuraTheme.muted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
                .padding(.horizontal, 24)
        }
    }

    // MARK: Empty / failed states

    private var emptyMessage: some View {
        VStack(spacing: 16) {
            Text("No bike route found to here — try another destination.")
                .font(.subheadline)
                .foregroundStyle(AuraTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            backButton
        }
        .frame(maxWidth: .infinity)
    }

    private var failedMessage: some View {
        VStack(spacing: 16) {
            Text("Couldn't fetch routes right now. Check your connection and try again.")
                .font(.subheadline)
                .foregroundStyle(AuraTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            backButton
        }
        .frame(maxWidth: .infinity)
    }

    private var backButton: some View {
        Button {
            router.screen = .plan
        } label: {
            Text("Back")
                .font(.headline)
                .foregroundStyle(AuraTheme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(AuraTheme.surface, in: Capsule())
                .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
    }

    // MARK: Start CTA

    private var startButton: some View {
        Button {
            router.screen = .ride(route: selected)
        } label: {
            Text("Start RIDE")
                .font(.headline)
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    selected != nil
                        ? AnyShapeStyle(AuraTheme.auroraGradient)
                        : AnyShapeStyle(AuraTheme.auroraGradient.opacity(0.35)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(selected == nil)
        .animation(.easeOut(duration: 0.18), value: selected?.id)
    }

    // MARK: Data loading

    private func loadRoutes() async {
        phase = .loading
        let origin = await CurrentLocationProvider.shared.current()
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

// MARK: - RouteOptionRow

private struct RouteOptionRow: View {
    let route: Route
    let isSelected: Bool
    let reduceMotion: Bool
    let onTap: () -> Void

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
        let miles = UnitConverter.miles(fromMeters: route.distanceMeters)
        let minutes = Int(route.estimatedDurationSeconds / 60)
        var text = String(format: "%.1f mi · %d min", miles, minutes)
        if route.elevationGainMeters > 0 {
            let feet = UnitConverter.feet(fromMeters: route.elevationGainMeters)
            text += String(format: " · %d ft↑", Int(feet))
        }
        return text
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: glyph)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.black : AuraTheme.text)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.black : AuraTheme.text)
                    Text(metricText)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? Color.black.opacity(0.65) : AuraTheme.muted)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.black)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(minHeight: 56)
            .background(
                isSelected
                    ? AnyShapeStyle(AuraTheme.route)
                    : AnyShapeStyle(AuraTheme.surface),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AuraTheme.surface)
                .frame(width: 24, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AuraTheme.surface)
                    .frame(width: 100, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AuraTheme.surface)
                    .frame(width: 140, height: 11)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(minHeight: 56)
        .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
