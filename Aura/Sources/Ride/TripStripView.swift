import SwiftUI
import AuraKit

/// The cruising-state trip strip pinned to the bottom of the navigate HUD: the road the
/// rider is on, the distance left, and the arrival ETA. Driven by a pure `CruisingState`
/// so it previews and reads without any guidance engine.
struct TripStripView: View {
    let state: CruisingState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var isStarting: Bool { state == .starting }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilityLabel)
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .padding(.vertical, AuraTheme.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(background)
            .animation(reduceMotion ? nil : .snappy, value: state)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder private var content: some View {
        if isStarting {
            Text("Starting…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: AuraTheme.Spacing.md) {
                if let street = state.streetName {
                    Text(street)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                Spacer(minLength: AuraTheme.Spacing.sm)
                metric(state.distanceRemaining ?? "–")
                metric(state.eta ?? "–")
            }
        }
    }

    private func metric(_ text: String) -> some View {
        Text(text)
            .font(AuraTheme.Typography.metricCockpit(20, relativeTo: .title3))
            .foregroundStyle(AuraTheme.textPrimary)
            .contentTransition(.numericText())
            .lineLimit(1)
    }

    @ViewBuilder private var background: some View {
        if AuraTheme.prefersOpaqueSurface(reduceTransparency: reduceTransparency, contrast) {
            AuraTheme.surface
        } else {
            AuraTheme.surface.opacity(0.55).background(.ultraThinMaterial)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        TripStripView(state: .init(streetName: "Penn Ave", distanceRemaining: "2.1 mi", eta: "4:38 PM",
                                   accessibilityLabel: "On Penn Ave, 2.1 miles to go, arriving 4:38 PM"))
        TripStripView(state: .init(streetName: "Boulevard of the Allies and then some more",
                                   distanceRemaining: "12.4 mi", eta: "5:02 PM",
                                   accessibilityLabel: "On Boulevard of the Allies and then some more, 12.4 miles to go, arriving 5:02 PM"))
        TripStripView(state: .init(streetName: nil, distanceRemaining: "0.3 mi", eta: "4:51 PM",
                                   accessibilityLabel: "0.3 miles to go, arriving 4:51 PM"))
        TripStripView(state: .starting)
    }
    .padding()
    .background(AuraTheme.background)
}
