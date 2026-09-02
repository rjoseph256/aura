import SwiftUI
import AuraCore

/// The join code's one voice (ROH-230): Saira cockpit numerals, a single tracking token,
/// size parameterized per surface. The join screen's per-character boxes are the deliberate
/// exception (spec §5) — every other rendering of a code goes through this.
struct JoinCodeText: View {
    let code: String
    var size: CGFloat = 40
    var textStyle: Font.TextStyle = .largeTitle
    var color: Color = AuraTheme.textPrimary

    /// The one tracking token — a code gets exactly one letter-spacing modifier, never a second.
    static let tracking: CGFloat = 4

    var body: some View {
        Text(code)
            .font(AuraTheme.Typography.metricCockpit(size, relativeTo: textStyle))
            .tracking(Self.tracking)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}
