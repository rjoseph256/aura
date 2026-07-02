import SwiftUI
import AuraCore
import AuraKit

/// The always-visible motivation hook in the sheet's peek header: a sentence with a number
/// plus a compact progress ring. Renders with no gesture (explicit spec gate).
struct WeeklyGlanceView: View {
    let week: WeeklyRideStats
    let goalMeters: Double
    let lastRide: RideSummary?
    let units: DistanceUnits

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedFraction: Double = 0

    private var fraction: Double { WeeklyGlance.ringFraction(week: week, goalMeters: goalMeters) }
    private var headline: String {
        WeeklyGlance.headline(week: week, goalMeters: goalMeters, lastRide: lastRide, units: units, now: Date())
    }

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.lg) {
            ZStack {
                Circle().stroke(AuraTheme.border, lineWidth: 5)
                Circle().trim(from: 0, to: animatedFraction)
                    .stroke(AuraTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 36, height: 36)

            Text(headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("home.glance")
        .onAppear { animate(to: fraction) }
        .onChange(of: fraction) { _, new in animate(to: new) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
        .accessibilitySortPriority(2)
    }

    private func animate(to target: Double) {
        guard !reduceMotion else { animatedFraction = target; return }
        withAnimation(.easeOut(duration: 0.9)) { animatedFraction = target }
    }
}
