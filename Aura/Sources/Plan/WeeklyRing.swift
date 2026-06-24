import SwiftUI
import AuraKit

/// Weekly-distance goal ring — the home screen's signature glance.
///
/// The arc encodes progress toward the rider's weekly goal (a cool slice of the aurora,
/// so the full cyan→violet→pink gradient stays reserved for the primary CTA). The center
/// shows the distance ridden this week. The arc fills on appear (reduce-motion aware) —
/// a single, meaningful state reveal, not decoration.
struct WeeklyRing: View {
    let stats: WeeklyRideStats
    let goalMeters: Double
    let units: DistanceUnits

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedFraction: Double = 0
    @ScaledMetric(relativeTo: .largeTitle) private var centerSize: CGFloat = 50

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }
    private var fraction: Double { stats.goalFraction(goalMeters: goalMeters) }

    private let diameter: CGFloat = 196
    private let stroke: CGFloat = 16

    var body: some View {
        ZStack {
            // Track — light enough to read as a ring waiting to fill.
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: stroke)

            // Progress arc — cool aurora slice, rounded caps, starting at 12 o'clock.
            Circle()
                .trim(from: 0, to: animatedFraction)
                .stroke(
                    AngularGradient(
                        colors: [AuraTheme.cyan, AuraTheme.violet],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            // Center readout
            VStack(spacing: 1) {
                Text(fmt.distanceValue(stats.distanceMeters))
                    .font(.system(size: centerSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(AuraTheme.text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)   // never overflow the fixed ring
                Text("\(fmt.distanceUnit) this week")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AuraTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: diameter - stroke * 2)   // keep the readout inside the ring
        }
        .frame(width: diameter, height: diameter)
        .onAppear { animate(to: fraction) }
        .onChange(of: fraction) { _, new in animate(to: new) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance this week")
        .accessibilityValue("\(fmt.distanceValue(stats.distanceMeters)) \(fmt.distanceUnit), \(stats.goalPercent(goalMeters: goalMeters)) percent of weekly goal")
    }

    private func animate(to target: Double) {
        guard !reduceMotion else { animatedFraction = target; return }
        withAnimation(.easeOut(duration: 0.9)) { animatedFraction = target }
    }
}
