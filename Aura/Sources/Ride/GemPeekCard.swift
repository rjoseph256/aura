import SwiftUI
import AuraCore

/// A soft, self-dismissing peek that rises for a Tier-2/3 gem. The pin remains on the map
/// as the durable object; this card is a shortcut. Visible for at least `minVisible` seconds
/// so a rider can reach it, then recedes on its own. Tapping it opens the detail sheet.
struct GemPeekCard: View {
    let gem: Gem
    let distanceText: String
    let onTap: () -> Void
    let onDismiss: () -> Void

    private let minVisible: Duration = .seconds(6)

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: GemPinView.symbol(for: gem.category))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AuraTheme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AuraTheme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(gem.name).font(.headline).foregroundStyle(AuraTheme.textPrimary)
                    Text(distanceText).font(.subheadline).foregroundStyle(AuraTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18).fill(AuraTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AuraTheme.hairline(.standard), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(gem.name), \(distanceText)"))
        .accessibilityHint(Text("Opens details"))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: gem.id) {
            try? await Task.sleep(for: minVisible)
            if !Task.isCancelled { onDismiss() }
        }
    }
}
