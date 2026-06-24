import SwiftUI
import AuraCore
import AuraKit

// MARK: - PlanView (Home / dashboard)

struct PlanView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @State private var query: String = ""
    @State private var rides: [Ride] = []
    @ScaledMetric(relativeTo: .title) private var brandSize: CGFloat = 24

    private var weekStats: WeeklyRideStats {
        RideAggregator.weekToDate(rides, now: Date())
    }
    private var lastRide: Ride? { RideAggregator.mostRecent(rides) }

    var body: some View {
        ZStack {
            AuraTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                DestinationSearchView(query: $query) { place in
                    router.remember(place)
                    router.screen = .preview(destination: place)
                }

                // Dashboard is hidden while actively searching (results take over).
                if query.isEmpty {
                    dashboard
                }

                Spacer(minLength: 0)

                freeRideButton
            }
        }
        .task { await loadRides() }
    }

    // MARK: Data

    private func loadRides() async {
        rides = (try? rideStore.allRides()) ?? []
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(AuraTheme.muted)
                Text("Aura")
                    .font(.system(size: brandSize, weight: .bold, design: .rounded))
                    .foregroundColor(AuraTheme.text)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
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
            VStack(spacing: 28) {
                weeklyBlock
                    .padding(.top, 24)

                if let lastRide {
                    lastRideSection(lastRide)
                }

                if !router.recents.isEmpty {
                    recentsSection
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Weekly block (ring + caption)

    private var weeklyBlock: some View {
        VStack(spacing: 14) {
            WeeklyRing(stats: weekStats,
                       goalMeters: settings.weeklyGoalMeters,
                       units: settings.units)
            Text(weeklyCaption)
                .font(.footnote.weight(.medium))
                .foregroundColor(AuraTheme.muted)
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

    // MARK: Last-ride section

    private func lastRideSection(_ ride: Ride) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Last ride")
            LastRideCard(ride: ride, units: settings.units) {
                router.selectedTab = .history
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: Recents

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Recents")
            VStack(spacing: 0) {
                ForEach(router.recents) { place in
                    RecentRow(place: place) {
                        router.screen = .preview(destination: place)
                    }
                    if place.id != router.recents.last?.id {
                        Divider()
                            .background(AuraTheme.bg)
                            .padding(.leading, 58)
                    }
                }
            }
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 24)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(AuraTheme.muted)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    // MARK: Free-ride CTA

    private var freeRideButton: some View {
        Button {
            router.screen = .ride(route: nil, destination: nil)
        } label: {
            ZStack {
                AuraTheme.auroraGradient
                Text("Free ride")
                    .font(.headline)
                    .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 8)
    }
}

// MARK: - RecentRow

private struct RecentRow: View {
    let place: Place
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: categoryIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(AuraTheme.violet)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.callout.weight(.medium))
                        .foregroundColor(AuraTheme.text)
                        .lineLimit(1)

                    Text(categoryLabel)
                        .font(.footnote)
                        .foregroundColor(AuraTheme.muted)
                }
                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AuraTheme.muted)
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 16)
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
