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
        // Refetch when CloudKit merges a remote ride, so the glance + last-ride stay live even
        // with the sheet at peek (the subscription is on the always-mounted container).
        .onChange(of: rideStore.syncRevision) { Task { await loadRides() } }
        .onChange(of: router.path) { syncSheet() }
        .onChange(of: searchExpanded) { syncSheet() }
        .onAppear { syncSheet() }
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
                        onJoin: { router.push(.joinRide) })
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
        .homeDashboardSheet(isPresented: $sheetPresented, peekHeight: peekHeight) {
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting).font(.footnote.weight(.medium)).foregroundStyle(AuraTheme.textSecondary)
                Text("Aura").font(AuraTheme.Typography.metricBrand(brandSize)).foregroundStyle(AuraTheme.textPrimary)
            }
            Spacer()
            headerControls
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    /// Maps-style utility cluster over the terrain — History + Settings, reached by pushing
    /// (which empties the dashboard sheet, so each opens full-screen with a back button). Uses
    /// the shipped cockpit control style, so Reduce Transparency / Motion / Contrast are handled.
    private var headerControls: some View {
        HStack(spacing: AuraTheme.Spacing.sm) {
            Button { router.push(.history) } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.hudControl)
            .accessibilityLabel("History")
            .accessibilityHint("Your past rides")
            .accessibilityIdentifier("home.history")

            Button { router.push(.settings) } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.hudControl)
            .accessibilityLabel("Settings")
            .accessibilityHint("App settings and preferences")
            .accessibilityIdentifier("home.settings")
        }
        // Utilities read after the primary "Where to?" (3), glance (2), and Explore/Join (1)
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
