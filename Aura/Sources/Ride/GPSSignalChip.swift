import SwiftUI
import AuraCore

/// Small HUD chip surfacing weak/lost GPS. Hidden when good. Composed VoiceOver label.
struct GPSSignalChip: View {
    let signal: SignalQuality

    var body: some View {
        if signal != .good {
            Label(signal == .lost ? "GPS lost" : "GPS weak",
                  systemImage: "location.slash.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(signal == .lost ? "GPS signal lost" : "GPS signal weak")
        }
    }
}
