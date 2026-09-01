import SwiftUI

// Home-scoped Liquid Glass helpers. All gate `if #available(iOS 26, *)` with the shipped
// styles as the pre-26 fallback. Under Reduce Transparency OR Increase Contrast we use the
// solid fallback even on iOS 26, so tinted content stays legible over a bright map. These are
// deliberately local to Home — the shared `.hudControl` / `.ctaSecondary` styles are untouched.

/// Groups sibling glass controls so they blend/morph on iOS 26; a plain pass-through before then.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = AuraTheme.Spacing.sm
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// A circular HUD control: Liquid Glass on iOS 26 (unless the user prefers solid surfaces),
/// otherwise the shipped `.hudControl` style.
struct GlassCircleButton<Label: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    private var preferSolid: Bool { reduceTransparency || contrast == .increased }

    var body: some View {
        if #available(iOS 26, *), !preferSolid {
            Button(action: action, label: label)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.hudControl)
        }
    }
}

/// A compact action chip: mint-tinted Liquid Glass on iOS 26, a mint capsule fallback otherwise.
struct HomeChip: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let systemImage: String
    let action: () -> Void

    private var preferSolid: Bool { reduceTransparency || contrast == .increased }

    var body: some View {
        if #available(iOS 26, *), !preferSolid {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            .tint(AuraTheme.accent)
        } else {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage).font(.footnote.weight(.semibold))
                    Text(title).font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(AuraTheme.accent)
                .padding(.horizontal, AuraTheme.Spacing.md)
                .padding(.vertical, AuraTheme.Spacing.sm + 2)
                .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast), in: .capsule)
                .overlay(Capsule().strokeBorder(AuraTheme.accent.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}
