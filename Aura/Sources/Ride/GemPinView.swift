import SwiftUI
import AuraCore

// AuraTheme lives in the app target (Aura/Sources/Theme) — the same module as this
// file — so AuraTheme.* below needs no extra import.

/// A single ambient gem pin on the ride map. An already-seen gem renders in a
/// calmer, filled-surface style so the map reads as "surfaced, not urgent";
/// tapping either state opens the gem's detail sheet via `onTap`.
struct GemPinView: View {
    let gem: Gem
    var isSeen: Bool = false
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            Image(systemName: GemPinView.symbol(for: gem.category))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSeen ? AuraTheme.accent : AuraTheme.onAccent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isSeen ? AuraTheme.surface : AuraTheme.accent))
                .overlay(Circle().stroke(isSeen ? AuraTheme.accent.opacity(0.6)
                                                : AuraTheme.background.opacity(0.6),
                                         lineWidth: isSeen ? 1.5 : 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(gem.name))
        .accessibilityHint(Text("Opens details"))
    }

    static func symbol(for category: GemCategory) -> String {
        switch category {
        case .viewpoint: return "mountain.2.fill"
        case .water: return "drop.fill"
        case .park: return "tree.fill"
        case .cafe: return "cup.and.saucer.fill"
        case .mural: return "paintpalette.fill"
        case .climb: return "arrow.up.forward"
        case .historic: return "building.columns.fill"
        case .landmark: return "star.fill"
        }
    }
}
