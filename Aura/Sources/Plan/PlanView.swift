import SwiftUI
import AuraCore
import AuraKit

// MARK: - PlanView (Home / dashboard)

struct PlanView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(SavedPlacesStore.self) private var savedPlaces
    @State private var query: String = ""
    @State private var summaries: [RideSummary] = []
    @State private var showJoinRide = false
    @State private var renameTarget: SavedPlace?
    @State private var renameText = ""
    @ScaledMetric(relativeTo: .title) private var brandSize: CGFloat = 24

    private var weekStats: WeeklyRideStats {
        RideAggregator.weekToDate(summaries, now: Date())
    }
    private var lastRide: RideSummary? { RideAggregator.mostRecent(summaries) }

    var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, AuraTheme.Spacing.lg)
                    .padding(.bottom, AuraTheme.Spacing.xl)

                DestinationSearchView(query: $query) { place in
                    router.remember(place)
                    router.push(.preview(place))
                }

                // Dashboard is hidden while actively searching (results take over).
                if query.isEmpty {
                    dashboard
                }

                Spacer(minLength: 0)

                joinRideButton
                freeRideButton
            }
        }
        .task { await loadRides() }
        // Refetch when CloudKit merges a remote ride, so the weekly ring and last-ride
        // card stay live on the dashboard (mirrors HistoryView's syncRevision refetch).
        .onChange(of: rideStore.syncRevision) { Task { await loadRides() } }
        .sheet(isPresented: $showJoinRide) {
            NavigationStack {
                GroupRideJoinView()
            }
        }
        .alert("Rename saved place", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let target = renameTarget {
                    savedPlaces.rename(id: target.id, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: Data

    private func loadRides() async {
        summaries = (try? rideStore.summaries()) ?? []
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AuraTheme.textSecondary)
                Text("Aura")
                    .font(AuraTheme.Typography.metricBrand(brandSize))
                    .foregroundStyle(AuraTheme.textPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Late ride?"
        }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: AuraTheme.Spacing.xxxl) {
                weeklyBlock
                    .padding(.top, AuraTheme.Spacing.xxl)

                if !savedPlaces.places.isEmpty {
                    savedSection
                }

                if let lastRide {
                    lastRideSection(lastRide)
                }

                if !visibleRecents.isEmpty {
                    recentsSection
                }
            }
            .padding(.bottom, AuraTheme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Weekly block (ring + caption)

    private var weeklyBlock: some View {
        VStack(spacing: AuraTheme.Spacing.lg) {
            WeeklyRing(stats: weekStats,
                       goalMeters: settings.weeklyGoalMeters,
                       units: settings.units)
            Text(weeklyCaption)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AuraTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var weeklyCaption: String {
        guard weekStats.rideCount > 0 else { return "Plan a ride to start your week" }
        let rides = "\(weekStats.rideCount) ride\(weekStats.rideCount == 1 ? "" : "s")"
        return "\(weekStats.goalPercent(goalMeters: settings.weeklyGoalMeters))% of \(goalLabel) · \(rides)"
    }

    /// Whole-unit goal label, e.g. "40 km" / "25 mi" (no decimals — it's a target).
    private var goalLabel: String {
        let value = settings.units == .metric
            ? settings.weeklyGoalMeters / 1000
            : settings.weeklyGoalMeters / 1609.344
        let unit = settings.units == .metric ? "km" : "mi"
        return "\(Int(value.rounded())) \(unit)"
    }

    // MARK: Saved

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            sectionHeader("Saved")
            VStack(spacing: 0) {
                ForEach(savedPlaces.places) { saved in
                    SavedPlaceRow(
                        saved: saved,
                        onTap: { router.push(.preview(saved.place)) },
                        onRename: { renameText = saved.name; renameTarget = saved },
                        onSetHome: { savedPlaces.setHome(id: saved.id) },
                        onRemoveHome: { savedPlaces.removeHome(id: saved.id) },
                        onDelete: { savedPlaces.delete(id: saved.id) }
                    )
                    if saved.id != savedPlaces.places.last?.id {
                        Divider()
                            .background(AuraTheme.border)
                            .padding(.leading, 58)
                    }
                }
            }
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    // MARK: Last-ride section

    private func lastRideSection(_ ride: RideSummary) -> some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            sectionHeader("Last ride")
            LastRideCard(summary: ride, units: settings.units) {
                router.selectedTab = .history
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    // MARK: Recents

    /// Recents already saved (Home or favorite) are surfaced in the Saved
    /// section instead, so they're filtered out here to avoid duplicates.
    private var visibleRecents: [Place] {
        router.recents.filter { !savedPlaces.isSaved($0) }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            sectionHeader("Recents")
            VStack(spacing: 0) {
                ForEach(visibleRecents) { place in
                    RecentRow(place: place) {
                        router.push(.preview(place))
                    }
                    if place.id != visibleRecents.last?.id {
                        Divider()
                            .background(AuraTheme.border)
                            .padding(.leading, 58)
                    }
                }
            }
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AuraTheme.textSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    // MARK: Join-a-ride CTA

    private var joinRideButton: some View {
        Button {
            showJoinRide = true
        } label: {
            Label("Join a ride", systemImage: "person.2.badge.plus")
                .font(.system(.headline, design: .rounded).weight(.semibold))
        }
        .buttonStyle(.ctaSecondary)
        .padding(.horizontal, AuraTheme.Spacing.xxl)
        .padding(.top, AuraTheme.Spacing.sm)
    }

    // MARK: Free-ride CTA

    private var freeRideButton: some View {
        Button("Explore") {
            router.push(.freeRide)
        }
        .buttonStyle(.ctaPrimary)
        .padding(.horizontal, AuraTheme.Spacing.xxl)
        .padding(.bottom, AuraTheme.Spacing.xxl)
        .padding(.top, AuraTheme.Spacing.sm)
    }
}

// MARK: - RecentRow

private struct RecentRow: View {
    let place: Place
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AuraTheme.Spacing.lg) {
                Image(systemName: categoryIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AuraTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)

                    Text(categoryLabel)
                        .font(.footnote)
                        .foregroundStyle(AuraTheme.textSecondary)
                }
                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
            .frame(minHeight: 56)
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var categoryIcon: String {
        switch place.category {
        case .brewery:   return "mug.fill"
        case .trailhead: return "figure.hiking"
        case .address:   return "mappin.circle.fill"
        case .custom:    return "mappin"
        }
    }

    private var categoryLabel: String {
        switch place.category {
        case .brewery:   return "Brewery"
        case .trailhead: return "Trail"
        case .address:   return "Address"
        case .custom:    return "Place"
        }
    }
}
