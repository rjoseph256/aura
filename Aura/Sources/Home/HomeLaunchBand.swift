import SwiftUI
import AuraCore

/// The one dominant launch band, pinned in the reachable lower area: a full-width lime
/// "Where to?" primary on top, with Explore + Join as a demoted secondary row beneath. Lime
/// lives only on the primary. Tapping the primary expands search.
struct HomeLaunchBand: View {
    let onWhereTo: () -> Void
    let onExplore: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            Button(action: onWhereTo) {
                Label("Where to?", systemImage: "magnifyingglass")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ctaPrimary)
            .accessibilityIdentifier("home.whereTo")
            .accessibilitySortPriority(3)

            HStack(spacing: AuraTheme.Spacing.sm) {
                Button("Explore", action: onExplore)
                    .buttonStyle(.ctaSecondary)
                    .frame(maxWidth: .infinity)
                    .accessibilitySortPriority(1)
                Button(action: onJoin) {
                    Label("Join a ride", systemImage: "person.2.badge.plus")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.ctaSecondary)
                .accessibilitySortPriority(1)
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }
}
