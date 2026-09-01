import SwiftUI

/// The flat map-chip treatment (ROH-222). One grammar over the map: frosted material
/// is for CONTROLS (`HUDControlButton`, `MapZoomControl`); flat scrim is for text
/// chips — this modifier. Reads the accessibility environment itself so a call site
/// cannot skip the Increase Contrast / Reduce Transparency branch.
enum MapChipStroke { case hairline, none }

private struct MapChipModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let stroke: MapChipStroke
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(shape.fill(AuraTheme.mapScrim(
                reduceTransparency: reduceTransparency, contrast)))
            .overlay {
                if case .hairline = stroke {
                    shape.strokeBorder(AuraTheme.hairline(contrast), lineWidth: 1)
                }
            }
    }
}

extension View {
    func mapChip(_ shape: some InsettableShape, stroke: MapChipStroke = .hairline) -> some View {
        modifier(MapChipModifier(shape: shape, stroke: stroke))
    }
}
