import SwiftUI
import AuraCore

/// A single peer's live marker on the group-ride map: a status-colored disc with the
/// rider's initial, a heading cone when a bearing is known, a soft live pulse (static
/// ring when Reduce Motion is on), and an optional name tag for decluttering.
struct PeerDotView: View {
    let displayName: String
    let status: PeerStatus
    let isSelf: Bool
    /// Degrees clockwise from north; nil draws no cone (no recent movement to infer from).
    let bearing: Double?
    let showsNameTag: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private static let discDiameter: CGFloat = 22
    private static let coneLength: CGFloat = 16

    private var discColor: Color {
        if isSelf { return .white }
        switch status {
        case .riding:   return AuraTheme.accent
        case .stopped:  return AuraTheme.warning
        case .dropped:  return AuraTheme.textSecondary
        case .awaiting: return AuraTheme.textSecondary
        }
    }

    private var initial: String {
        String(displayName.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            if showsNameTag {
                nameTag
            }
            ZStack {
                pulseRing
                cone
                disc
            }
            .frame(width: Self.discDiameter + Self.coneLength, height: Self.discDiameter + Self.coneLength)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(displayName), \(statusAccessibilityLabel)"))
    }

    private var statusAccessibilityLabel: String {
        if isSelf { return "you" }
        switch status {
        case .riding: return "riding"
        case .stopped: return "stopped"
        case .dropped: return "no signal"
        case .awaiting: return "waiting to start"
        }
    }

    @ViewBuilder
    private var pulseRing: some View {
        if reduceMotion {
            Circle()
                .stroke(discColor.opacity(0.4), lineWidth: 2)
                .frame(width: Self.discDiameter + 10, height: Self.discDiameter + 10)
        } else {
            Circle()
                .stroke(discColor.opacity(isPulsing ? 0 : 0.5), lineWidth: 2)
                .frame(width: Self.discDiameter + (isPulsing ? 18 : 6),
                       height: Self.discDiameter + (isPulsing ? 18 : 6))
        }
    }

    @ViewBuilder
    private var cone: some View {
        if let bearing {
            Triangle()
                .fill(discColor.opacity(0.55))
                .frame(width: 10, height: Self.coneLength)
                .offset(y: -(Self.discDiameter / 2 + Self.coneLength / 2 - 2))
                .rotationEffect(.degrees(bearing))
        }
    }

    private var disc: some View {
        ZStack {
            Circle()
                .fill(discColor)
                .frame(width: Self.discDiameter, height: Self.discDiameter)
            Circle()
                .strokeBorder(AuraTheme.background, lineWidth: 1.5)
                .frame(width: Self.discDiameter, height: Self.discDiameter)
            Text(initial)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(isSelf || status == .stopped ? AuraTheme.background : AuraTheme.onAccent)
        }
    }

    private var nameTag: some View {
        Text(displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AuraTheme.textPrimary)
            .padding(.horizontal, AuraTheme.Spacing.xs)
            .padding(.vertical, 2)
            .background(AuraTheme.surface.opacity(0.85), in: Capsule())
    }
}

/// A minimal upward-pointing triangle, used as the peer's heading cone.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
