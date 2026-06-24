import SwiftUI
import AuraCore

// MARK: - PlanView (Home / Plan screen)

struct PlanView: View {
    @Environment(AppRouter.self) private var router
    @State private var query: String = ""

    var body: some View {
        ZStack {
            AuraTheme.bg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Top bar: wordmark
                VStack(spacing: 6) {
                    Text("Aura")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(AuraTheme.text)

                    Text("Plan your ride in Pittsburgh")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(AuraTheme.muted)
                }
                .padding(.top, 20)
                .padding(.bottom, 24)

                // ── Search field (DestinationSearchView)
                DestinationSearchView(query: $query) { place in
                    router.remember(place)
                    router.screen = .preview(destination: place)
                }

                // ── Recents / empty state list area — hidden while actively searching
                if query.isEmpty {
                    recentsSection
                        .padding(.top, 16)
                }

                Spacer(minLength: 0)

                // ── Bottom CTA: Free ride
                freeRideButton
                    .padding(.bottom, 0) // safe area handled by safeAreaInset
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 0)
            }
        }
    }

    // MARK: - Recents section

    @ViewBuilder
    private var recentsSection: some View {
        if router.recents.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Recents")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AuraTheme.muted)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(router.recents) { place in
                        RecentRow(place: place) {
                            router.screen = .preview(destination: place)
                        }
                        if place.id != router.recents.last?.id {
                            Divider()
                                .background(AuraTheme.surface)
                                .padding(.leading, 60)
                                .padding(.horizontal, 24)
                        }
                    }
                }
                .background(AuraTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 48)
            Text("Search a place to plan a route —\nor start a free ride.")
                .font(.system(size: 15))
                .foregroundColor(AuraTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer().frame(height: 48)
        }
    }

    // MARK: - Free ride CTA

    private var freeRideButton: some View {
        Button {
            router.screen = .ride(route: nil)
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AuraTheme.violet)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AuraTheme.text)
                        .lineLimit(1)

                    Text(categoryLabel)
                        .font(.system(size: 13))
                        .foregroundColor(AuraTheme.muted)
                }
                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
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
