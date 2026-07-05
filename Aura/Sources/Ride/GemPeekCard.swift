import SwiftUI
import UIKit
import AuraCore

/// A soft, self-dismissing peek that drops in below the back button for a Tier-2/3 gem. The
/// pin remains on the map as the durable object; this card is a shortcut. Visible for at least
/// `minVisible` seconds so a rider can reach it, then recedes on its own. Tapping it opens the
/// detail sheet. Tier-3 (haptic) gems get a larger, fuller treatment — bigger badge and type
/// plus the `why` line — so the standout attractions read as more of an event than a Tier-2 peek.
struct GemPeekCard: View {
    let gem: Gem
    let distanceText: String
    let onTap: () -> Void
    let onDismiss: () -> Void

    private let minVisible: Duration = .seconds(6)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tier 3 is the featured treatment: ~50% larger, and it fills the extra room with the `why` line.
    private var isFeatured: Bool { gem.tier == .cardHaptic }
    private var scale: CGFloat { isFeatured ? 1.5 : 1.0 }

    /// Live (OSM) gems carry no human curation, so the peek card footnotes its source —
    /// both as an honest signal to the rider and to satisfy ODbL attribution.
    private var isLive: Bool { gem.source == .live }

    /// Spoken category word for the composed VoiceOver label (name + category + distance).
    private var categorySpokenName: String {
        switch gem.category {
        case .viewpoint: return "viewpoint"
        case .water: return "water feature"
        case .park: return "park"
        case .cafe: return "cafe"
        case .mural: return "mural"
        case .climb: return "climb"
        case .historic: return "historic site"
        case .landmark: return "landmark"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12 * scale) {
                Image(systemName: GemPinView.symbol(for: gem.category))
                    .font(.system(size: 16 * scale, weight: .semibold))
                    .foregroundStyle(AuraTheme.onAccent)
                    .frame(width: 34 * scale, height: 34 * scale)
                    .background(Circle().fill(AuraTheme.accent))
                VStack(alignment: .leading, spacing: isFeatured ? 4 : 2) {
                    Text(gem.name)
                        .font(isFeatured ? .title2.weight(.semibold) : .headline)
                        .foregroundStyle(AuraTheme.textPrimary)
                    Text(distanceText)
                        .font(isFeatured ? .headline : .subheadline)
                        .foregroundStyle(AuraTheme.textSecondary)
                    if isFeatured, let why = gem.why {
                        Text(why)
                            .font(.subheadline)
                            .foregroundStyle(AuraTheme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isLive {
                        Text("via OpenStreetMap")
                            .font(.caption2)
                            .foregroundStyle(AuraTheme.textSecondary.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12 * scale)
            .background(RoundedRectangle(cornerRadius: 18 * scale).fill(AuraTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 18 * scale)
                .stroke(AuraTheme.hairline(.standard), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        // One composed VoiceOver element: name, category-derived glyph, and distance read
        // together as a single stop. The OSM footnote is presentational attribution, not
        // additive information the rider needs read aloud, so it's folded in via `.combine`
        // rather than called out with its own label. The durable `GemPinView` on the map is a
        // separate view with its own `.accessibilityLabel`/`.accessibilityHint`, so it stays
        // independently focusable — this card is a shortcut, not the sole way to reach the gem.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(gem.name), \(categorySpokenName), \(distanceText)"))
        .accessibilityHint(Text("Opens details"))
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        .task(id: gem.id) {
            try? await Task.sleep(for: minVisible)
            if !Task.isCancelled { onDismiss() }
        }
        .onAppear {
            // Polite heads-up when the card appears. UIAccessibility's `.announcement`
            // notification queues behind whatever VoiceOver is already speaking rather than
            // interrupting it (unlike `.screenChanged`/`.layoutChanged`, which move focus and
            // cut off current speech) — so this reads as a courteous aside, not a demand for
            // attention, and the card is never the sole way to reach the gem.
            UIAccessibility.post(notification: .announcement, argument: "\(gem.name) nearby")
        }
    }
}
