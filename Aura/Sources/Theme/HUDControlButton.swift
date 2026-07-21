import SwiftUI
import AuraCore

struct HUDControlButton: ButtonStyle {
    enum Role { case normal, destructive }
    var role: Role = .normal
    var isActive = false
    /// Drawn-circle size and tap-region size. `.standard` (44 pt) for stationary chrome;
    /// `.ride` grows only the tap region for a moving rider (ROH-75).
    var metrics: HUDControlMetrics = .standard
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(width: CGFloat(metrics.size), height: CGFloat(metrics.size))
            .background(backgroundView)
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            // The tap region can extend past the drawn circle as invisible padding, so a
            // moving rider gets a larger target without the control gaining visual weight.
            // The metrics themselves are unit-tested (HUDControlMetricsTests); that the region
            // this frame produces is actually hit-testable is verified on device — the ROH-75
            // feel is only judgeable on a real ride, not in the simulator.
            .frame(width: CGFloat(metrics.resolvedHitTarget), height: CGFloat(metrics.resolvedHitTarget))
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch role {
        case .destructive: return AuraTheme.destructive
        case .normal: return isActive ? AuraTheme.accent : AuraTheme.textPrimary
        }
    }

    @ViewBuilder private var backgroundView: some View {
        if AuraTheme.prefersOpaqueSurface(reduceTransparency: reduceTransparency, contrast) {
            AuraTheme.surface
        } else {
            Color.clear.background(.ultraThinMaterial)
        }
    }
}

extension ButtonStyle where Self == HUDControlButton {
    static var hudControl: HUDControlButton { .init() }
    static func hudControl(active: Bool = false,
                           role: HUDControlButton.Role = .normal,
                           metrics: HUDControlMetrics = .standard) -> HUDControlButton {
        .init(role: role, isActive: active, metrics: metrics)
    }
}
