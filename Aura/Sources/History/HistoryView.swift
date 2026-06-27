import SwiftUI
import AuraCore
import AuraKit

/// Ride history — a clean, scannable list of past rides on the near-black Aura canvas.
/// Each row glances: a tinted icon badge, date + summary caption, and the hero distance numeral.
struct HistoryView: View {
    @Environment(RideStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var summaries: [RideSummary] = []
    @State private var selected: Ride?
    @State private var appeared = false
    @ScaledMetric(relativeTo: .largeTitle) private var emptyGlyph: CGFloat = 56

    var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if store.isEphemeral {
                    ephemeralBanner
                }
                Group {
                    if summaries.isEmpty {
                        emptyState
                    } else {
                        rideList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Rides")
        .onAppear {
            // Reload on every appearance (e.g. returning from a finished ride).
            // onAppear runs synchronously and isn't cancellable like .task, so rows
            // are never left gated invisible behind an interrupted entrance flag.
            summaries = (try? store.summaries()) ?? []
            if !appeared {
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            }
        }
        .sheet(item: $selected) { ride in
            RideSummaryView(ride: ride)
        }
    }

    // MARK: - List

    private var rideList: some View {
        List {
            ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                RideRow(summary: summary, units: settings.units)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = try? store.ride(id: summary.id) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .modifier(EntranceModifier(index: index, appeared: appeared, reduceMotion: reduceMotion))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { delete(summary) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func delete(_ summary: RideSummary) {
        try? store.delete(id: summary.id)
        summaries.removeAll { $0.id == summary.id }
        WidgetRefresh.reload(rideStore: store, settings: settings)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AuraTheme.Spacing.lg) {
            ZStack {
                // Faint accent glow behind the glyph.
                Circle()
                    .fill(AuraTheme.accent.opacity(0.18))
                    .frame(width: 140, height: 140)
                    .blur(radius: 44)

                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: emptyGlyph, weight: .regular))
                    .foregroundStyle(AuraTheme.accent)
            }
            .padding(.bottom, AuraTheme.Spacing.xs)

            Text("No rides yet")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)

            Text("Start a free ride or navigate somewhere — your rides land here.")
                .font(.subheadline)
                .foregroundStyle(AuraTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .lineSpacing(2)
        }
        .padding()
    }

    // MARK: - Ephemeral-store banner

    private var ephemeralBanner: some View {
        HStack(spacing: AuraTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(AuraTheme.destructive)
            Text("Rides aren't being saved on this device.")
                .font(.footnote)
                .foregroundStyle(AuraTheme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AuraTheme.Spacing.lg)
        .padding(.vertical, AuraTheme.Spacing.sm)
        .frame(maxWidth: .infinity)
        .background(AuraTheme.surface)
    }
}

// MARK: - Row

private struct RideRow: View {
    let summary: RideSummary
    let units: DistanceUnits

    private var isNavigate: Bool { summary.kind == .navigate }
    private var symbol: String { isNavigate ? "location.north.line.fill" : "bicycle" }
    // Mono-lime: both ride kinds share the accent. The free/navigate distinction is
    // carried non-chromatically — by the differing SF Symbol and its weight, not hue.
    private var symbolWeight: Font.Weight { isNavigate ? .semibold : .medium }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    private var caption: String {
        let lead: String
        if let name = summary.destinationName, !name.isEmpty {
            lead = name
        } else {
            lead = isNavigate ? "Navigated" : "Free ride"
        }
        let climb = "\(fmt.elevationValue(summary.elevationGainMeters)) \(fmt.elevationUnit)"
        return "\(lead) · \(fmt.minutes(summary.movingTimeSeconds)) · ↑ \(climb)"
    }

    private var distance: String { fmt.distanceValue(summary.distanceMeters) }

    private var distanceUnit: String { fmt.distanceUnit.uppercased() }

    @ViewBuilder
    private var leadingThumbnail: some View {
        let coords = summary.thumbnailCoordinates
        if coords.count > 1 {
            RouteThumbnail(coordinates: coords, lineColor: AuraTheme.accent, lineWidth: 2)
        } else {
            Image(systemName: symbol)
                .font(.headline.weight(symbolWeight))
                .foregroundStyle(AuraTheme.accent)
        }
    }

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.lg) {
            // Leading — a thumbnail of the actual route (or an accent kind badge when
            // the ride has no recorded track). Kind is shown by the symbol, not by hue.
            leadingThumbnail
                .frame(width: 54, height: 42)
                .background(AuraTheme.accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.md, style: .continuous))

            // Middle — date + summary caption.
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
                    .lineLimit(1)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AuraTheme.Spacing.sm)

            // Trailing — hero distance numeral.
            VStack(alignment: .trailing, spacing: 0) {
                Text(distance)
                    .font(AuraTheme.Typography.metricBrand(22))
                    .foregroundStyle(AuraTheme.textPrimary)
                    .monospacedDigit()
                Text(distanceUnit)
                    .font(AuraTheme.Typography.unit)
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
        .padding(.vertical, AuraTheme.Spacing.md)
        .frame(minHeight: 64)
    }
}

// MARK: - Staggered entrance

/// Fades + slides each row up a few points, delayed by index (capped).
/// Fully bypassed under reduce-motion: rows render immediately, no offset.
private struct EntranceModifier: ViewModifier {
    let index: Int
    let appeared: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(
                    .easeOut(duration: 0.4).delay(min(Double(index) * 0.04, 0.4)),
                    value: appeared
                )
        }
    }
}
