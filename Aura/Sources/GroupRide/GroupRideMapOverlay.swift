import SwiftUI
import AuraCore

/// A single peer's live marker on the group-ride map: an upright round identity head (a stable
/// per-rider hue + a disambiguated monogram), a bold outlined heading pointer that retracts to a
/// plain disc when no bearing is known, a status glyph (pause / no-signal), a clock-driven live
/// pulse, and an optional name tag. Identity (hue + monogram) is preserved across every status so
/// riders stay tell-apart-able; status rides on high-area cues (opacity + glyph + pulse-presence).
/// All animation inputs are injected (`bearing` already deadbanded, `pulsePhase` clock-driven), so
/// the view holds no animation `@State`.
struct PeerDotView: View {
    let monogram: String
    let displayName: String
    let status: PeerStatus
    let identityColor: Color
    /// Contrast-correct monogram ink for `identityColor` (light on dark hues, dark on light).
    let identityInk: Color
    let isSelf: Bool
    /// Degrees clockwise from north; nil retracts the pointer to a plain disc.
    let bearing: Double?
    /// 0…1 pulse phase; 0 means no pulse (driver passes 0 under Reduce Motion / when not riding).
    let pulsePhase: Double
    let showsNameTag: Bool

    private static let discDiameter: CGFloat = 22
    private static let pointerLength: CGFloat = 14

    private var headColor: Color {
        if isSelf { return AuraTheme.textPrimary }
        switch status {
        case .riding, .stopped, .awaiting: return identityColor      // identity hue preserved
        case .dropped: return identityColor.opacity(0.45)            // ghost
        }
    }
    private var isHollow: Bool { status == .awaiting }
    private var showsPointer: Bool { bearing != nil && status == .riding }

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            if showsNameTag { nameTag }
            ZStack {
                pulseRing
                pointer
                head
                statusBadge
            }
            .frame(width: Self.discDiameter + Self.pointerLength,
                   height: Self.discDiameter + Self.pointerLength)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(displayName), \(statusAccessibilityLabel)"))
    }

    // Pulse is a pure function of the injected phase — no @State, so it survives status morphs.
    // pulsePhase 0 (driver decides: not riding, or Reduce Motion) → a calm static ring.
    @ViewBuilder private var pulseRing: some View {
        if status == .riding && pulsePhase > 0 {
            let grow = 6 + 12 * pulsePhase
            Circle().stroke(headColor.opacity(0.5 * (1 - pulsePhase)), lineWidth: 2)
                .frame(width: Self.discDiameter + grow, height: Self.discDiameter + grow)
        } else if status == .riding {
            Circle().stroke(headColor.opacity(0.4), lineWidth: 2)     // static ring (RM / paused)
                .frame(width: Self.discDiameter + 8, height: Self.discDiameter + 8)
        }
    }

    // Bold, dark-outlined pointer; rotates with the already-deadbanded/coarsened bearing the driver
    // supplies. Only the pointer rotates — the head (monogram) never spins, so it stays legible.
    @ViewBuilder private var pointer: some View {
        if showsPointer, let bearing {
            Triangle()
                .fill(headColor)
                .overlay(Triangle().stroke(AuraTheme.background, lineWidth: 1.5))
                .frame(width: 12, height: Self.pointerLength)
                .offset(y: -(Self.discDiameter / 2 + Self.pointerLength / 2 - 2))
                .rotationEffect(.degrees(bearing))
        }
    }

    private var head: some View {
        ZStack {
            Circle().fill(isHollow ? Color.clear : headColor)
                .frame(width: Self.discDiameter, height: Self.discDiameter)
            Circle().strokeBorder(isHollow ? headColor : AuraTheme.background, lineWidth: 1.5)
                .frame(width: Self.discDiameter, height: Self.discDiameter)
            Text(monogram)
                .font(.system(size: monogram.count > 1 ? 8 : 10, weight: .bold, design: .rounded))
                .foregroundStyle(isHollow ? headColor : (isSelf ? AuraTheme.background : identityInk))
        }
    }

    // High-area, glanceable status glyph (pause / no-signal), overlaid on the head corner.
    @ViewBuilder private var statusBadge: some View {
        switch status {
        case .stopped:
            badge(systemName: "pause.fill", tint: AuraTheme.warning)
        case .dropped:
            badge(systemName: "wifi.slash", tint: AuraTheme.textSecondary)
        case .riding, .awaiting:
            EmptyView()
        }
    }
    private func badge(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(tint)
            .padding(2)
            .background(Circle().fill(AuraTheme.background))
            .offset(x: Self.discDiameter / 2 - 2, y: -Self.discDiameter / 2 + 2)
    }

    private var nameTag: some View {
        Text(displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AuraTheme.textPrimary)
            .padding(.horizontal, AuraTheme.Spacing.xs)
            .padding(.vertical, 2)
            .background(AuraTheme.surface.opacity(0.85), in: Capsule())
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
