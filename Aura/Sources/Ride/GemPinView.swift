import SwiftUI
import AuraCore

// AuraTheme lives in the app target (Aura/Sources/Theme) — the same module as this
// file — so AuraTheme.* below needs no extra import.

/// A single ambient gem pin on the ride map. An already-seen gem renders in a
/// calmer, filled-surface style so the map reads as "surfaced, not urgent";
/// tapping either state opens the gem's detail sheet via `onTap`.
///
/// Styling also branches on `gem.source`: curated and personal gems are
/// hand-vouched-for, so they render full-strength. `.live` gems come from the
/// raw OSM feed with no human curation behind them, so they render quieter —
/// a dimmer, hollow treatment — to keep curation legible as the stronger signal.
struct GemPinView: View {
    let gem: Gem
    var isSeen: Bool = false
    var onTap: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLive: Bool { gem.source == .live }

    var body: some View {
        Button(action: onTap) {
            Image(systemName: GemPinView.symbol(for: gem.category))
                .font(.system(size: isLive ? 13 : 15, weight: .semibold))
                .foregroundStyle(fillForeground)
                .frame(width: 30, height: 30)
                .background(pinBackground)
                .overlay(Circle().stroke(strokeColor, lineWidth: strokeWidth))
                .opacity(isLive ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .snappy, value: isSeen)
        .accessibilityLabel(Text(gem.name))
        .accessibilityHint(Text("Opens details"))
    }

    /// Curated/personal keep the existing solid-fill-vs-seen-outline treatment. Live gems are
    /// always hollow (never solid-filled), regardless of seen state, so "live" stays visually
    /// distinct from "curated, already seen."
    private var pinBackground: some View {
        Circle().fill(isLive ? AnyShapeStyle(AuraTheme.surface.opacity(0.55))
                             : AnyShapeStyle(isSeen ? AuraTheme.surface : AuraTheme.accent))
    }

    private var fillForeground: Color {
        isLive ? AuraTheme.accent.opacity(0.7) : (isSeen ? AuraTheme.accent : AuraTheme.onAccent)
    }

    private var strokeColor: Color {
        isLive ? AuraTheme.accent.opacity(0.4)
               : (isSeen ? AuraTheme.accent.opacity(0.6) : AuraTheme.background.opacity(0.6))
    }

    // Fixed `.standard`-width stroke — no colorSchemeContrast branching here. The pin's
    // legibility comes from its solid glyph + background, not the hairline, so a single
    // width is enough across contrast settings.
    private var strokeWidth: CGFloat {
        isLive ? 1 : (isSeen ? 1.5 : 2)
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
