import SwiftUI

/// Route endpoint markers (ROH-221). Deliberately NOT in the puck vocabulary: the
/// preview's origin can be the denied-permission fallback coordinate (spec §4).
/// The ink seat is a LARGER circle UNDER the mint ring (a .background on a same-size
/// ring renders inside it and adds nothing — plan-review finding).
struct OriginRingView: View {
    var body: some View {
        ZStack {
            Circle().fill(AuraTheme.background).frame(width: 20, height: 20)   // ink seat
            Circle().strokeBorder(AuraTheme.accent, lineWidth: 3)
                .frame(width: 16, height: 16)
        }
        .accessibilityHidden(true)
    }
}

/// Filled destination marker: ink seat, mint disc, ink flag glyph.
struct DestinationMarkerView: View {
    var body: some View {
        ZStack {
            Circle().fill(AuraTheme.background).frame(width: 26, height: 26)
            Circle().fill(AuraTheme.accent).frame(width: 22, height: 22)
            Image(systemName: "flag.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AuraTheme.onAccent)
        }
        .accessibilityHidden(true)
    }
}
