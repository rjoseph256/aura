import SwiftUI

struct HUDControlButton: ButtonStyle {
    var isActive = false
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(isActive ? AuraTheme.accent : AuraTheme.textPrimary)
            .frame(width: size, height: size)
            .background(backgroundView)
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
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
}
