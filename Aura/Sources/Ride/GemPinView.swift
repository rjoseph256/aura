import SwiftUI
import AuraCore

// AuraTheme lives in the app target (Aura/Sources/Theme) — the same module as this
// file — so AuraTheme.* below needs no extra import.

/// A single ambient gem pin on the ride map. Tier styling, seen-state, and tap
/// handling arrive in Plan 2; this slice is a plain category-glyph marker.
struct GemPinView: View {
    let gem: Gem

    var body: some View {
        Image(systemName: Self.symbol(for: gem.category))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AuraTheme.onAccent)
            .frame(width: 30, height: 30)
            .background(Circle().fill(AuraTheme.accent))
            .overlay(Circle().stroke(AuraTheme.background.opacity(0.6), lineWidth: 2))
            .accessibilityLabel(Text(gem.name))
    }

    private static func symbol(for category: GemCategory) -> String {
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
