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

    @State private var query = ""
    @State private var summaries: [RideSummary] = []
    @State private var didLoad = false
    @State private var renameTarget: SavedPlace?
    @State private var renameText = ""
    @State private var searchExpanded = false
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
        // Fetch weather for the greeting, and again if authorization changes. Gated on real
        // authorization so we never show weather for the location fallback when permission is
        // absent (spec: no permission → weather hidden). Silent-hides on any failure.
        .task { await refreshWeather() }
        .onChange(of: location.authorization) { Task { await refreshWeather() } }
        // Refetch when CloudKit merges a remote ride, so the glance + last-ride stay live even
        // with the sheet at peek (the subscription is on the always-mounted container).
        .onChange(of: rideStore.syncRevision) { Task { await loadRides() } }
        .onChange(of: router.path) { syncSheet() }
        .onChange(of: searchExpanded) { syncSheet() }
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
            HomeBackdrop(renderer: renderer, riderCoordinate: nil, placeName: nil)

            VStack(spacing: 0) {
                header.padding(.top, AuraTheme.Spacing.lg)
                Spacer(minLength: 0)
                if !searchExpanded {
                    HomeLaunchBand(
                        onWhereTo: { searchExpanded = true },
                        onExplore: { router.push(.freeRide) },
                        onJoin: { router.push(.joinRide) },
                        onSaved: {
                            if searchExpanded { searchExpanded = false }
                            selectedDetent = .large
                            revealSavedNonce += 1
                        },
                        hasSaved: !savedPlaces.places.isEmpty)
                        .padding(.bottom, peekHeight + AuraTheme.Spacing.md) // sit above the peek sheet
                }
            }

            if searchExpanded {
                SearchOverlay(
                    query: $query,
                    onPick: { place in router.remember(place); router.push(.preview(place)) },
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

    private func loadRides() async {
        summaries = (try? rideStore.summaries()) ?? []
        didLoad = true
    }

    /// Refreshes greeting weather only when location is actually authorized — otherwise
    /// `location.current()` returns a city fallback and we'd show weather for a place the
    /// rider isn't at. Failures inside `refresh` are already swallowed (weather hides).
    private func refreshWeather() async {
        guard location.authorization == .authorized else { return }
        await weather.refresh(near: location.current(), now: Date())
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

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late ride?"
        }
    }

    private var visibleRecents: [Place] { router.recents.filter { !savedPlaces.isSaved($0) } }

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
                                  onTap: { router.push(.preview(saved.place)) },
                                  onRename: { renameText = saved.name; renameTarget = saved },
                                  onSetHome: { savedPlaces.setHome(id: saved.id) },
                                  onRemoveHome: { savedPlaces.removeHome(id: saved.id) },
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
                    RecentRow(place: place) { router.push(.preview(place)) }
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
