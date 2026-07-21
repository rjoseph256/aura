import SwiftUI
import AuraCore

/// A vertical +/- zoom pill for the interactive Mapbox surfaces (ROH-57): a discoverable,
/// one-tap alternative to pinch so a moving, one-handed, bar-mounted rider can step the map
/// scale with a thumb. Two stacked tap zones — "+" over "−" — share one translucent capsule
/// (the familiar maps-zoom grouping), split by a hairline.
///
/// Sized by `HUDControlMetrics` like the sibling map controls: the pill stays light over the
/// map, while each half's *height* — the dimension that separates + from − — grows to the
/// metrics' hit target. `.ride` (56 pt) for the live-ride HUDs where the rider is moving;
/// `.standard` (44 pt, the Apple floor) on the stationary route-preview map. Because the two
/// halves are fused, they tile exactly at the full hit height with no overlap at the divider
/// (a symmetric invisible overhang, as the circular controls use, would make the halves' tap
/// regions collide). The pure zoom arithmetic lives in `MapZoomStep`; this view is only the
/// button surface and its two callbacks.
struct MapZoomControl: View {
    /// Drawn/tap sizing. `.ride` on the moving HUDs, `.standard` on the stationary preview.
    var metrics: HUDControlMetrics = .standard
    var onZoomIn: () -> Void
    var onZoomOut: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            half(systemName: "plus", label: "Zoom in", action: onZoomIn)
            Rectangle()
                .fill(AuraTheme.hairline(contrast))
                .frame(width: CGFloat(metrics.size), height: 1)
            half(systemName: "minus", label: "Zoom out", action: onZoomOut)
        }
        .background(backgroundView)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(AuraTheme.hairline(contrast)))
        // One pill, two buttons: kept as separate accessibility elements ("Zoom in" / "Zoom
        // out") so each is an independent, actionable target for VoiceOver, Switch Control,
        // Voice Control, and Full Keyboard Access — the pattern the ROH-57 spec calls for.
    }

    private func half(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                // Drawn area == tap area, so the two halves tile flush with no ambiguous
                // overlap at the divider. Width tracks the sibling controls' drawn circle so
                // the pill lines up in the cluster's column.
                .frame(width: CGFloat(metrics.size), height: CGFloat(metrics.resolvedHitTarget))
                .contentShape(Rectangle())
        }
        .buttonStyle(ZoomHalfButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(label)
    }

    @ViewBuilder private var backgroundView: some View {
        if AuraTheme.prefersOpaqueSurface(reduceTransparency: reduceTransparency, contrast) {
            AuraTheme.surface
        } else {
            Color.clear.background(.ultraThinMaterial)
        }
    }
}

/// Press feedback for a zoom half, matching `HUDControlButton`'s dim-on-press so the pill
/// reads as the same family of control. Reduce Motion drops the fade to an instant change.
private struct ZoomHalfButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    HStack(spacing: 40) {
        MapZoomControl(metrics: .ride, onZoomIn: {}, onZoomOut: {})
        MapZoomControl(metrics: .standard, onZoomIn: {}, onZoomOut: {})
    }
    .padding()
    .background(AuraTheme.background)
}
