import SwiftUI

struct CTAButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, tertiary, destructive }
    var variant: Variant = .primary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.semibold))
            .frame(maxWidth: variant == .tertiary ? nil : .infinity)
            .frame(height: variant == .tertiary ? 40 : 50)
            .padding(.horizontal, variant == .tertiary ? AuraTheme.Spacing.md : AuraTheme.Spacing.lg)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary: return AuraTheme.onAccent
        case .destructive: return AuraTheme.onDestructive
        case .secondary, .tertiary: return AuraTheme.accent
        }
    }
    @ViewBuilder private var background: some View {
        switch variant {
        case .primary: AuraTheme.accent
        case .destructive: AuraTheme.destructive
        case .secondary:
            RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous)
                .strokeBorder(AuraTheme.accent, lineWidth: 1.5)
        case .tertiary: Color.clear
        }
    }
}

extension ButtonStyle where Self == CTAButtonStyle {
    static var ctaPrimary: CTAButtonStyle { .init(variant: .primary) }
    static var ctaSecondary: CTAButtonStyle { .init(variant: .secondary) }
    static var ctaTertiary: CTAButtonStyle { .init(variant: .tertiary) }
    static var ctaDestructive: CTAButtonStyle { .init(variant: .destructive) }
}
