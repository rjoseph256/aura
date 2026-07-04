import SwiftUI
import AuraCore

/// The one dominant launch band, pinned in the reachable lower area: a full-width mint
/// "Where to?" primary on top, with Explore / Join a ride / Saved as a demoted chip row
/// beneath. Mint lives only on the primary fill; the chips are glass (iOS 26) or a mint
/// capsule fallback. Tapping the primary expands search.
struct HomeLaunchBand: View {
    let onWhereTo: () -> Void
    let onExplore: () -> Void
    let onJoin: () -> Void
    /// Reveals the Saved section in the dashboard sheet. Defaults keep older call sites valid.
    var onSaved: () -> Void = {}
    /// The Saved chip only shows when there is at least one saved place.
    var hasSaved: Bool = false

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

            GlassGroup(spacing: AuraTheme.Spacing.sm) {
                HStack(spacing: AuraTheme.Spacing.sm) {
                    HomeChip(title: "Explore", systemImage: "safari", action: onExplore)
                        .accessibilitySortPriority(1)
                        .accessibilityIdentifier("home.explore")
                    HomeChip(title: "Join a ride", systemImage: "person.2.badge.plus", action: onJoin)
                        .accessibilitySortPriority(1)
                        .accessibilityIdentifier("home.join")
                    if hasSaved {
                        HomeChip(title: "Saved", systemImage: "bookmark", action: onSaved)
                            .accessibilitySortPriority(1)
                            .accessibilityIdentifier("home.saved")
                            .transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: hasSaved)
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }
}
