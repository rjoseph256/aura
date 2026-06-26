import SwiftUI

struct HUDControlButton: ButtonStyle {
    enum Role { case normal, destructive }
    var role: Role = .normal
    var isActive = false
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(backgroundView)
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .destructive: return AuraTheme.destructive
        case .normal: return isActive ? AuraTheme.accent : AuraTheme.textPrimary
        }
    }

    @ViewBuilder private var backgroundView: some View {
        if reduceTransparency {
            AuraTheme.surface
        } else {
            Color.clear.background(.ultraThinMaterial)
        }
    }
}

extension ButtonStyle where Self == HUDControlButton {
    static var hudControl: HUDControlButton { .init() }
    static func hudControl(active: Bool) -> HUDControlButton { .init(isActive: active) }
    static func hudControl(role: HUDControlButton.Role) -> HUDControlButton { .init(role: role) }
}
