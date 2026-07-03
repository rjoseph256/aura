import SwiftUI
import AuraCore

/// Small HUD chip surfacing weak/lost GPS. Hidden when good. Composed VoiceOver label.
struct GPSSignalChip: View {
    let signal: SignalQuality
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if signal != .good {
            // Poor signal escalates to the amber warning treatment — an amber glyph + label
            // and an amber border — so it reads as a caution, not neutral chrome. Navigation
            // does not pause; this only styles the existing weak/lost indicator.
            Label(signal == .lost ? "GPS lost" : "GPS weak",
                  systemImage: "location.slash.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AuraTheme.warning)
                .padding(.horizontal, AuraTheme.Spacing.sm).padding(.vertical, AuraTheme.Spacing.xs)
                .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast), in: Capsule())
                .overlay(Capsule().strokeBorder(AuraTheme.warning.opacity(signal == .lost ? 0.9 : 0.55)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(signal == .lost ? "GPS signal lost" : "GPS signal weak")
        }
    }
}
