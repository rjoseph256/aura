import SwiftUI
import AuraCore
import AuraKit

/// Compact next-maneuver preview shown under the turn band ("then → Highland Ave"), so the
/// rider can plan one turn ahead. Decorative for VoiceOver — its "then …" text is composed
/// into the turn card's single accessibility label by `TurnCardPresenter`, so the chip itself
/// is hidden to avoid a double read.
struct ThenChip: View {
    let next: NextManeuver

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.xs) {
            Text("then")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AuraTheme.textSecondary)
            Image(systemName: ManeuverIcon.symbol(for: next.maneuver))
                .font(.caption.weight(.bold))
                .foregroundStyle(AuraTheme.accent)
            Text(next.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, AuraTheme.Spacing.md)
        .padding(.vertical, AuraTheme.Spacing.xs)
        .background(AuraTheme.surface.opacity(0.85), in: Capsule())
        .overlay(Capsule().strokeBorder(AuraTheme.border))
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        AuraTheme.background.ignoresSafeArea()
        ThenChip(next: NextManeuver(maneuver: Maneuver(kind: .turn, modifier: .left),
                                    label: "Highland Ave"))
    }
}
