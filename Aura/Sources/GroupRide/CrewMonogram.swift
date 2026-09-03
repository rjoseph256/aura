import SwiftUI
import AuraCore

/// A rider's identity disc (ROH-228, gate-1 board): latched hue + monogram for a peer;
/// WHITE for self — "white = me" is the puck grammar, and the rider marker is never
/// accent-mint. `isSelf` is explicit so a lookup miss can never masquerade as self.
struct CrewMonogram: View {
    let isSelf: Bool
    let colorIndex: Int
    let label: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelf ? AuraTheme.textPrimary : AuraTheme.riderColor(colorIndex))
                .frame(width: size, height: size)
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isSelf ? AuraTheme.background : AuraTheme.riderInk(colorIndex))
        }
        .accessibilityHidden(true)   // the row's combined label carries the name
    }
}
