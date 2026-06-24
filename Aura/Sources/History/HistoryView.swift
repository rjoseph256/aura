import SwiftUI
import AuraCore
import AuraKit

/// Ride history — a clean, scannable list of past rides on the near-black Aura canvas.
/// Each row glances: a tinted icon badge, date + summary caption, and the hero distance numeral.
struct HistoryView: View {
    @Environment(RideStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var rides: [Ride] = []
    @State private var selected: Ride?
    @State private var appeared = false

    var body: some View {
        ZStack {
            AuraTheme.bg.ignoresSafeArea()

            if rides.isEmpty {
                emptyState
            } else {
                rideList
            }
        }
        .navigationTitle("Rides")
        .task {
            rides = (try? store.allRides()) ?? []
            // First-appear entrance flag; harmless if reduce-motion short-circuits it.
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
        }
        .sheet(item: $selected) { ride in
            RideSummaryView(ride: ride)
        }
    }

    // MARK: - List

    private var rideList: some View {
        List {
            ForEach(Array(rides.enumerated()), id: \.element.id) { index, ride in
                RideRow(ride: ride)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = ride }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .modifier(EntranceModifier(index: index, appeared: appeared, reduceMotion: reduceMotion))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { delete(ride) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func delete(_ ride: Ride) {
        try? store.delete(id: ride.id)
        rides.removeAll { $0.id == ride.id }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                // Faint aurora glow behind the glyph.
                Circle()
                    .fill(AuraTheme.violet.opacity(0.18))
                    .frame(width: 140, height: 140)
                    .blur(radius: 44)

                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(AuraTheme.auroraGradient)
            }
            .padding(.bottom, 6)

            Text("No rides yet")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(AuraTheme.text)

            Text("Start a free ride or navigate somewhere — your rides land here.")
                .font(.system(size: 14))
                .foregroundStyle(AuraTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .lineSpacing(2)
        }
        .padding()
    }
}

// MARK: - Row

private struct RideRow: View {
    let ride: Ride

    private var stats: RideStats { ride.stats ?? .zero }
    private var isNavigate: Bool { ride.kind == .navigate }
    private var accent: Color { isNavigate ? AuraTheme.cyan : AuraTheme.route }
    private var symbol: String { isNavigate ? "location.north.line.fill" : "bicycle" }

    private var caption: String {
        let kind = isNavigate ? "Navigated" : "Free ride"
        let minutes = Int(stats.movingTimeSeconds / 60)
        let feet = Int(UnitConverter.feet(fromMeters: stats.elevationGainMeters).rounded())
        return "\(kind) · \(minutes) min · ↑ \(feet) ft"
    }

    private var distance: String {
        String(format: "%.1f", UnitConverter.miles(fromMeters: stats.distanceMeters))
    }

    var body: some View {
        HStack(spacing: 14) {
            // Leading icon badge — tinted square of the kind's accent.
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 40, height: 40)

            // Middle — date + summary caption.
            VStack(alignment: .leading, spacing: 3) {
                Text(ride.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AuraTheme.text)
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(AuraTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Trailing — hero distance numeral.
            VStack(alignment: .trailing, spacing: 0) {
                Text(distance)
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(AuraTheme.text)
                    .monospacedDigit()
                Text("MI")
                    .font(AuraTheme.unitLabel)
                    .foregroundStyle(AuraTheme.muted)
            }
        }
        .padding(.vertical, 12)
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
