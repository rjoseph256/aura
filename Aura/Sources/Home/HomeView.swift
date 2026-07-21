import SwiftUI
import AuraCore
import AuraKit

/// Home — the "Terrain hero canvas". Always-mounted container: owns the backdrop, the launch
/// band, the search overlay, the dashboard sheet, and all state + data subscriptions.
/// Replaces PlanView as the Ride-tab root.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(SavedPlacesStore.self) private var savedPlaces
    @Environment(LocationService.self) private var location
    @Environment(WeatherStore.self) private var weather

    @Environment(\.scenePhase) private var scenePhase

    @State private var query = ""
    @State private var summaries: [RideSummary] = []
    @State private var didLoad = false
    @State private var renameTarget: SavedPlace?
    @State private var renameText = ""
    @State private var searchExpanded = false
    @State private var mapModel = HomeMapModel(initial: .initial(forRider: nil))
    @State private var didResolveInitialCenter = false
    @State private var flyToTarget: Coordinate?
    /// The search-picked destination, rendered as a persistent dropped pin on the live map.
    /// Cleared on a real camera reset (ride completed / cold launch) — see `resolveCenter`.
    @State private var focusedPlace: Place?
    /// Kept in sync (via onChange/onAppear) so the dashboard sheet shows only at Home root and
    /// when not searching — a pushed screen (Explore, preview, join) is never covered by the
    /// sheet, and search never stacks with it. Using @State (not a derived binding) so the
    /// sheet reliably presents/dismisses when the nav path changes.
    @State private var sheetPresented = true
    // Drives the dashboard sheet's detent so the Saved chip can raise it to `.large`. The
    // literal peek height matches `peekHeight`'s base at default Dynamic Type.
    @State private var selectedDetent: PresentationDetent = .height(250)
    // Bumped on every Saved tap so the sheet re-scrolls to the Saved section even when it is
    // already at `.large` (a detent-value change alone wouldn't fire).
    @State private var revealSavedNonce = 0
    @ScaledMetric(relativeTo: .title) private var brandSize: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var peekHeight: CGFloat = 250

    private let renderer: TerrainSnapshotRendering = MapboxTerrainSnapshotter()

    private var weekStats: WeeklyRideStats { RideAggregator.weekToDate(summaries, now: Date()) }
    private var lastRide: RideSummary? { RideAggregator.mostRecent(summaries) }
    private var mode: HomeMode {
        HomeMode.resolve(hasCompletedOnboarding: settings.didCompleteOnboarding,
                         hasRides: !summaries.isEmpty, auth: location.authorization)
    }

    /// Recomputes dashboard-sheet visibility from nav + search state.
    private func syncSheet() { sheetPresented = router.path.isEmpty && !searchExpanded }

    var body: some View {
        Group {
            if mode == .firstRun {
                FirstRunHomeView(renderer: renderer) {
                    settings.didCompleteOnboarding = true
                    searchExpanded = true
                }
            } else {
                populated
            }
        }
        .task { await loadRides() }
        // One-shot cold-launch center resolve → rider (authorized) or curated fallback.
        .task {
            if !didResolveInitialCenter {
                didResolveInitialCenter = true
                await resolveCenter(reset: false)
            }
        }
        // Fetch weather for the greeting, and again if authorization changes. Gated on real
        // authorization so we never show weather for the location fallback when permission is
        // absent (spec: no permission → weather hidden). Silent-hides on any failure.
        .task { await refreshWeather() }
        .onChange(of: location.authorization) { Task { await refreshWeather() } }
        // The ambient monitor publishes a new coarse fix roughly every 500 m (distanceFilter);
        // refresh weather when it changes so the greeting tracks the rider without a continuous
        // high-power locate.
        .onChange(of: location.lastKnown) { Task { await refreshWeather() } }
        // Refetch when CloudKit merges a remote ride, so the glance + last-ride stay live even
        // with the sheet at peek (the subscription is on the always-mounted container).
        .onChange(of: rideStore.syncRevision) { Task { await loadRides() } }
        .onChange(of: router.path) {
            syncSheet()
            if router.path.isEmpty {
                mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .becameTopActive) // no reset
            } else {
                mapModel.freezeIdleFromLive()
                mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .resignedTop)
            }
        }
        .onChange(of: searchExpanded) { syncSheet() }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                mapModel.freezeIdleFromLive()
                mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .background)
            }
        }
        // Real post-ride reset: the ride HUD sets router.isRideActive; its true→false edge is a
        // ride ending.
        .onChange(of: router.isRideActive) { wasActive, isActive in
            if wasActive && !isActive, HomeMapCamera.shouldReset(on: .rideCompleted) {
                Task { await resolveCenter(reset: true) }
            }
        }
        // Align the selected detent with the sheet's *scaled* peek detent (the @State literal
        // is only correct at default Dynamic Type); keeps the selection binding valid at all sizes.
        .onAppear { syncSheet(); selectedDetent = .height(peekHeight) }
        .alert("Rename saved place", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let t = renameTarget { savedPlaces.rename(id: t.id, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: Populated layout

    private var populated: some View {
        ZStack {
            HomeMapCanvas(renderer: renderer, model: mapModel, savedPlaces: savedPlaces.places,
                          onSelectSaved: { saved in
                              mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .activate)
                              flyToTarget = saved.place.coordinate
                              // Keep the "Ride here" card + focus in sync with whichever pin was
                              // tapped — otherwise a different saved pin's tap would fly the map
                              // while leaving a stale/mismatched card up for a previous place.
                              focusedPlace = saved.place
                          },
                          flyTo: $flyToTarget, focusedPlace: focusedPlace, bottomInset: peekHeight)

            VStack(spacing: 0) {
                header.padding(.top, AuraTheme.Spacing.lg)
                if location.authorization != .authorized {
                    HomeLocationHint()
                        .padding(.horizontal, AuraTheme.Spacing.xxl)
                        .padding(.top, AuraTheme.Spacing.sm)
                }
                Spacer(minLength: 0)
                if !searchExpanded { launchSlot }
            }

            if searchExpanded {
                SearchOverlay(
                    query: $query,
                    onPick: { place in
                        // Picking a place flies the Home map to it (PO decision 2026-07-20),
                        // rather than opening route preview.
                        router.remember(place)
                        searchExpanded = false
                        mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .activate)
                        flyToTarget = place.coordinate
                        focusedPlace = place
                    },
                    onCollapse: { searchExpanded = false })
            }
        }
        .homeDashboardSheet(isPresented: $sheetPresented, selection: $selectedDetent,
                            revealSaved: revealSavedNonce, peekHeight: peekHeight) {
            VStack(spacing: AuraTheme.Spacing.lg) {
                WeeklyGlanceView(week: weekStats, goalMeters: settings.weeklyGoalMeters,
                                 lastRide: lastRide, units: settings.units)
                if let lastRide {
                    LastRideCard(summary: lastRide, units: settings.units) { router.push(.history) }
                } else if !didLoad {
                    RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous)
                        .fill(AuraTheme.surface).frame(height: 88) // quiet loading placeholder
                }
            }
        } body: {
            sheetBody
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                greetingLine
                Text("Aura").font(AuraTheme.Typography.metricBrand(brandSize)).foregroundStyle(AuraTheme.textPrimary)
            }
            Spacer()
            headerControls
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    /// Greeting with the weather folded inline ("Good evening · ☀ 72° clear"). Weather shows
    /// only when a display-eligible snapshot exists. Held to one line (`lineLimit(1)` +
    /// `minimumScaleFactor`) so weather arriving/leaving never wraps and never pushes the
    /// "Aura" wordmark down. Read as one composed VoiceOver element.
    private var greetingLine: some View {
        let snap = weather.displaySnapshot(now: Date())
        return HStack(spacing: 4) {
            Text(greeting)
            if let snap {
                Text("·").foregroundStyle(AuraTheme.textSecondary.opacity(0.6))
                Image(systemName: WeatherGreeting.symbolName(for: snap.condition))
                    .foregroundStyle(AuraTheme.accent)
                    .accessibilityHidden(true)
                Text(WeatherGreeting.temperatureText(snap.temperature, locale: .current))
                    .foregroundStyle(AuraTheme.textPrimary)
                let word = WeatherGreeting.text(for: snap.condition)
                if !word.isEmpty { Text(word) }
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(AuraTheme.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WeatherGreeting.accessibilityText(
            greeting: greeting, snapshot: snap, locale: .current))
        // Reads with the glance tier, before the chips (1) and utilities (-1).
        .accessibilitySortPriority(2)
    }

    /// Maps-style utility cluster over the terrain — History + Settings, reached by pushing
    /// (which empties the dashboard sheet, so each opens full-screen with a back button). Uses
    /// the shipped cockpit control style, so Reduce Transparency / Motion / Contrast are handled.
    private var headerControls: some View {
        GlassGroup(spacing: AuraTheme.Spacing.sm) {
            HStack(spacing: AuraTheme.Spacing.sm) {
                GlassCircleButton { router.push(.history) } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("History")
                .accessibilityHint("Your past rides")
                .accessibilityIdentifier("home.history")

                GlassCircleButton { router.push(.settings) } label: {
                    Image(systemName: "gearshape.fill")
                }
                .accessibilityLabel("Settings")
                .accessibilityHint("App settings and preferences")
                .accessibilityIdentifier("home.settings")
            }
        }
        // Utilities read after the primary "Where to?" (3), glance (2), and the chips (1)
        // in VoiceOver — never before the dominant action, despite sitting at the top.
        .accessibilitySortPriority(-1)
    }

    @ViewBuilder private var sheetBody: some View {
        VStack(spacing: AuraTheme.Spacing.xxxl) {
            if !savedPlaces.places.isEmpty { savedSection }
            if !visibleRecents.isEmpty { recentsSection }
        }
        .padding(.vertical, AuraTheme.Spacing.lg)
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            sectionHeader("Saved")
            listCard {
                ForEach(savedPlaces.places) { saved in
                    SavedPlaceRow(saved: saved,
                                  onTap: { leaveHome(pushing: .preview(saved.place)) },
                                  onRename: { renameText = saved.name; renameTarget = saved },
                                  onSetHome: { savedPlaces.setHome(id: saved.id) },
                                  onRemoveHome: { savedPlaces.removeHome(id: saved.id) },
                                  onSetResurface: { savedPlaces.setResurface(id: saved.id, $0) },
                                  onDelete: { savedPlaces.delete(id: saved.id) })
                    if saved.id != savedPlaces.places.last?.id { rowDivider }
                }
            }
        }
        .id("saved")
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            sectionHeader("Recents")
            listCard {
                ForEach(visibleRecents) { place in
                    RecentRow(place: place) { leaveHome(pushing: .preview(place)) }
                    if place.id != visibleRecents.last?.id { rowDivider }
                }
            }
        }
    }

    private func listCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
    }

    private var rowDivider: some View { Divider().background(AuraTheme.border).padding(.leading, 58) }

    // Sentence-case section header (not an uppercase "eyebrow" — the slop gate forbids those).
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AuraTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Data & lifecycle helpers
// Extracted into an extension so the main `HomeView` body stays within SwiftLint's
// type_body_length limit; behavior is unchanged.
private extension HomeView {
    func loadRides() async {
        summaries = (try? rideStore.summaries()) ?? []
        didLoad = true
    }

    /// "Ride here" on the focused-place card: clears the pin and hands off to route preview via
    /// `leaveHome` (single-renderer-safe teardown), same as any other saved/recent pick.
    func rideToFocusedPlace() {
        let target = focusedPlace
        focusedPlace = nil
        if let target { leaveHome(pushing: .preview(target)) }
    }

    /// The launch band's slot: a focused (flown-to) place takes it over with a "Ride here"
    /// card instead of stacking alongside the band, so there is always exactly one bottom
    /// action surface.
    @ViewBuilder
    var launchSlot: some View {
        if let focusedPlace {
            FocusedPlaceCard(
                place: focusedPlace,
                onRideHere: { rideToFocusedPlace() },
                onDismiss: { self.focusedPlace = nil })
                .padding(.bottom, peekHeight + AuraTheme.Spacing.md) // sit above the peek sheet
        } else {
            HomeLaunchBand(
                onWhereTo: { searchExpanded = true },
                onExplore: { leaveHome(pushing: .freeRide) },
                onJoin: { leaveHome(pushing: .joinRide) },
                onSaved: {
                    if searchExpanded { searchExpanded = false }
                    selectedDetent = .large
                    revealSavedNonce += 1
                },
                hasSaved: !savedPlaces.places.isEmpty)
                .padding(.bottom, peekHeight + AuraTheme.Spacing.md) // sit above the peek sheet
        }
    }

    /// Leaves Home for a pushed route that will mount its own map (ride HUD, join flow). Commits
    /// `.idle` (tearing down the live map THIS update, no animation on that edge) before pushing
    /// on the NEXT runloop tick, so SwiftUI removes `HomeLiveMap` before the destination's map
    /// mounts — never two live maps at once (single-renderer invariant).
    func leaveHome(pushing route: AppRoute) {
        mapModel.freezeIdleFromLive()
        mapModel.phase = .idle
        DispatchQueue.main.async { router.push(route) }
    }

    /// One-shot center resolve → rider (authorized) or curated fallback. Writes the model's cameras.
    func resolveCenter(reset: Bool) async {
        let camera: HomeMapCamera
        if location.authorization == .authorized {
            camera = HomeMapCamera.initial(forRider: await location.current(for: .coarse))
        } else {
            camera = HomeMapCamera.initial(forRider: nil)
        }
        if reset {
            mapModel.reset(to: camera)
            focusedPlace = nil
        } else {
            mapModel.idleCamera = camera
            mapModel.liveCamera = camera
        }
    }

    /// Refreshes greeting weather only when location is actually authorized — otherwise
    /// `location.current(for:)` returns a city fallback and we'd show weather for a place the
    /// rider isn't at. Uses the coarse (low-power ambient) fix — the greeting doesn't need a
    /// precise locate. Failures inside `refresh` are already swallowed (weather hides).
    func refreshWeather() async {
        guard location.authorization == .authorized else { return }
        await weather.refresh(near: location.current(for: .coarse), now: Date())
    }

    var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late ride?"
        }
    }

    var visibleRecents: [Place] { router.recents.filter { !savedPlaces.isSaved($0) } }
}
