import SwiftUI
import AuraCore
import AuraKit

struct RideSummaryView: View {
    let ride: Ride
    /// When true, the ride finished but couldn't be persisted — warn the rider rather
    /// than letting it silently vanish from History.
    var saveFailed: Bool = false

    /// Injected by the ride-end pushed route to return Home via `popToRoot()`. `nil` for the
    /// History sheet, which dismisses itself via `@Environment(\.dismiss)`.
    var onDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @Environment(RideStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var isLongest = false
    @State private var animatedMeters: Double = 0
    @State private var revealed = false
    @State private var shareImage: RideShareImage?

    // Brand (SF Pro Rounded) is fixed-size, so @ScaledMetric drives Dynamic Type for the
    // hero. (Cockpit Saira self-scales via relativeTo: — not used here.)
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 44

    private var stats: RideStats { ride.stats ?? .zero }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: settings.units) }
    private var metric: Bool { settings.units == .metric }
    private var routeSegments: [[Coordinate]] {
        ride.segments.map { $0.points.map(\.coordinate) }.filter { $0.count > 1 }
    }

    var body: some View {
        // Bound once: `routeSegments` maps every point of every segment, and this project's
        // rule (see Ride.swift, RideRecorder.swift, GPXTrack.swift) is to never read that kind
        // of property twice inside a SwiftUI `body`.
        let segs = routeSegments
        ScrollView {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.xl) {
                if !segs.isEmpty {
                    StaticRouteMap(segments: segs)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous)
                                .strokeBorder(AuraTheme.hairline(contrast), lineWidth: 1)
                        )
                        .padding(.top, AuraTheme.Spacing.lg)
                        .opacity(revealed ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: revealed)
                }

                titleBlock
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.05), value: revealed)

                heroDistance
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.10), value: revealed)

                ElevationProfileBand(content: ElevationProfileContent(ride: ride, units: settings.units))
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.15), value: revealed)

                supportingStats
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.20), value: revealed)

                if ride.stats != nil {
                    Group {
                        if let shareImage {
                            ShareLink(item: shareImage.fileURL,
                                      preview: SharePreview("Aura ride", image: shareImage.preview)) {
                                Text("Share")
                            }
                        } else {
                            Button("Share") {}.disabled(true)
                        }
                    }
                    .buttonStyle(.ctaSecondary)
                    .padding(.top, AuraTheme.Spacing.md)
                }

                Button("Done") {
                    if let onDone { onDone() } else { dismiss() }
                }
                    .buttonStyle(.ctaPrimary)
                    .padding(.top, AuraTheme.Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AuraTheme.Spacing.xl)
            .padding(.bottom, AuraTheme.Spacing.xxxl)
        }
        .background(AuraTheme.background.ignoresSafeArea())
        .onAppear {
            computeRecord()
            startAppearance()
        }
        .task {
            guard ride.stats != nil, shareImage == nil else { return }
            await Task.yield()   // let the entrance animation start before the synchronous render
            let content = ShareCardContent(ride: ride, units: settings.units)
            shareImage = RideCardRenderer.make(content)
        }
    }

    // MARK: Sections

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
                Text("Nice ride").font(.largeTitle.bold()).foregroundStyle(AuraTheme.textPrimary)
                if let name = ride.destinationName, !name.isEmpty {
                    Text("to \(name)")
                        .font(.subheadline)
                        .foregroundStyle(AuraTheme.secondaryText(contrast))
                        .lineLimit(2)
                }
            }
            // "Nice ride" stays. Flipping the headline would change how the app addresses the
            // rider over something Aura got wrong; the badge carries the fact instead. This
            // screen is where a rider lands *because* the History row looked odd, so it gets
            // the detail line.
            if ride.isUnfinished {
                UnfinishedRideBadge(checkpointedAt: ride.checkpointedAt, style: .full)
            }
            // No trophy on a truncated ride: a lime celebration directly under a grey "anything
            // after that wasn't saved" contradicts it. The reverse cost — a rider who genuinely
            // rode their longest and is denied it because the end was lost — is accepted;
            // claiming a record from a recording we just called incomplete is worse.
            if isLongest && !ride.isUnfinished {
                Label("Longest ride yet", systemImage: "trophy.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.accent)
                    .padding(.horizontal, AuraTheme.Spacing.lg).padding(.vertical, AuraTheme.Spacing.sm)
                    .background(AuraTheme.accent.opacity(0.14), in: Capsule())
            }
            if saveFailed {
                Label(saveFailureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Since ROH-107 a ride whose `finish()` throws still leaves its pause checkpoint in
    /// History, wearing the marker — so the old wording asserted absence while the app was
    /// displaying presence. The coordinator publishes the surviving row's `checkpointedAt` on
    /// the failed-finish route (`RideSessionCoordinator.finish()`), which is what makes this
    /// branch reachable; `endedAt` is always stamped there, so gating on the marker rather than
    /// `isUnfinished` is the same test and says what the first sentence depends on.
    private var saveFailureMessage: String {
        ride.checkpointedAt != nil
            ? "Aura couldn't save the end of this ride. What was recorded is in History."
            : "Couldn't save this ride — it won't appear in History."
    }

    /// The hero metric: distance, leading the recap. Counts up to the formatted value, with
    /// the unit and a "distance" label. Reads as one VoiceOver element using the final value.
    private var heroDistance: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xs) {
                Group {
                    // Unfinished rides skip the count-up the same way Reduce Motion does:
                    // celebrating a number the same screen calls incomplete is the trophy
                    // contradiction again, in motion.
                    if reduceMotion || ride.isUnfinished {
                        Text(fmt.distanceValue(stats.distanceMeters))
                    } else {
                        CountUpText(meters: animatedMeters, format: fmt.distanceValue)
                    }
                }
                .font(AuraTheme.Typography.metricBrand(heroSize))
                .monospacedDigit()
                .foregroundStyle(AuraTheme.textPrimary)

                Text(fmt.distanceUnit)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AuraTheme.secondaryText(contrast))
            }
            Text("distance")
                .font(.caption)
                .foregroundStyle(AuraTheme.secondaryText(contrast))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance, \(fmt.distanceValue(stats.distanceMeters)) \(fmt.distanceUnitSpoken)")
        .accessibilityIdentifier(RideTestID.summaryDistance)
    }

    /// The three supporting stats in an even row that reflows to a vertical stack at
    /// accessibility text sizes so nothing clips.
    private var supportingStats: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xxl) {
                supportingCells
            }
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                supportingCells
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var supportingCells: some View {
        stat(fmt.minutes(stats.movingTimeSeconds), "moving")
        stat(fmt.speedValue(stats.maxSpeedMetersPerSecond, decimals: 1), metric ? "km/h top" : "mph top")
    }

    /// One value+label metric, left-aligned, combined into a single VoiceOver element.
    private func stat(_ value: String, _ label: String) -> some View {
        StatPair(value: value, label: label, context: .brand, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    // MARK: Behavior

    private func startAppearance() {
        // `revealed` drives the per-section staggered reveal via their .animation(value:)
        // modifiers, which are themselves nil under Reduce Motion; the count-up animates the
        // Animatable CountUpText separately, and is skipped on the same terms `heroDistance`
        // skips it so the two can't disagree about which value is on screen.
        revealed = true
        if reduceMotion || ride.isUnfinished {
            animatedMeters = stats.distanceMeters
        } else {
            withAnimation(.easeOut(duration: 0.7)) { animatedMeters = stats.distanceMeters }
        }
    }

    /// "Longest ride yet" when this ride's distance is the max across all saved rides (and
    /// there's more than one). Reads the lightweight `summaries()` projection rather than
    /// faulting every ride's externally-stored track.
    private func computeRecord() {
        let summaries = (try? store.summaries()) ?? []
        isLongest = RideAggregator.isLongest(rideID: ride.id,
                                             distanceMeters: stats.distanceMeters,
                                             among: summaries)
    }
}

/// A number that ticks up to its target: SwiftUI interpolates `meters` (its `animatableData`)
/// each frame and the body re-formats with the screen's own formatter, so the final frame is
/// byte-identical to the static value (no visible snap). Reduce Motion uses a plain Text instead.
private struct CountUpText: View, Animatable {
    var meters: Double
    var format: (Double) -> String

    var animatableData: Double {
        get { meters }
        set { meters = newValue }
    }

    var body: some View { Text(format(meters)) }
}
