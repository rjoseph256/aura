import SwiftUI
import AuraCore
import AuraKit

/// The ride summary's elevation band — the "how hard was it" effort story. A dumb
/// projection of `ElevationProfileContent`: a silhouette + climb callout for a real
/// climb, a slim "Mostly flat" line otherwise, and nothing for pre-elevation rides.
/// The silhouette reuses the pure-Canvas `ElevationSparkline` (same language as the
/// share card, scaled up). Self-scaling per ride: the silhouette shows shape; the
/// callout number carries the true magnitude.
struct ElevationProfileBand: View {
    let content: ElevationProfileContent
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        switch content.kind {
        case .profile(let samples):
            profile(samples)
        case .flat:
            flatLine
        case .unavailable:
            EmptyView()
        }
    }

    private func profile(_ samples: [Double]) -> some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            Label("\(content.climbedValue) \(content.climbedUnit) climbed",
                  systemImage: "arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.accent)

            ElevationSparkline(elevations: samples,
                               stroke: AuraTheme.accent,
                               fill: AuraTheme.accent.opacity(0.18),
                               lineWidth: 2)
                .frame(height: 110)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AuraTheme.hairline(contrast))
                        .frame(height: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel ?? "")
    }

    private var flatLine: some View {
        Label(flatText, systemImage: "minus")
            .font(.subheadline)
            .foregroundStyle(AuraTheme.secondaryText(contrast))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.accessibilityLabel ?? "")
    }

    // Visible flat copy uses the mid-dot / abbreviated-unit voice; the spoken VoiceOver
    // string is the pure `content.accessibilityLabel` (unit-tested in Task 2).
    private var flatText: String {
        content.isTrivialClimb
            ? "Mostly flat"
            : "Mostly flat · \(content.climbedValue) \(content.climbedUnit) climbed"
    }
}
