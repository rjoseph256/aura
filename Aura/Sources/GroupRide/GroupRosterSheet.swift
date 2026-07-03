import SwiftUI
import AuraCore

/// The draggable crew-roster panel over the group-ride map: collapsed to a grab handle,
/// an avatar stack, and a one-line summary; expanded to the full `RosterRow` list. Pure
/// presentation — every row, count, and label is derived from the `[RosterRow]` this view
/// is handed, so it previews standalone and composes with a live session without knowing
/// about one (Task 17 wires that up).
struct GroupRosterSheet: View {
    let rows: [RosterRow]
    /// Starting detent. Real presentation always starts collapsed (the default);
    /// previews use `true` to show the expanded list without a tap.
    @State private var isExpanded: Bool

    init(rows: [RosterRow], startsExpanded: Bool = false) {
        self.rows = rows
        _isExpanded = State(initialValue: startsExpanded)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var summary: RosterSummary { RosterSummary(rows: rows) }
    private var isSoloCrew: Bool { rows.count <= 1 }

    var body: some View {
        VStack(spacing: 0) {
            handle
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isExpanded ? "Collapse crew roster" : "Expand crew roster")
                .accessibilityHint(summary.spokenSummary)
                .accessibilityAddTraits(.isButton)

            if isExpanded {
                expandedList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                collapsedSummary
                    .transition(.opacity)
            }
        }
        .padding(.bottom, AuraTheme.Spacing.md)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: AuraTheme.Radius.xl)
                .strokeBorder(AuraTheme.hairline(contrast))
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: isExpanded)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func toggle() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeOut(duration: 0.22)) { isExpanded.toggle() }
        }
    }

    // MARK: - Handle

    private var handle: some View {
        Capsule()
            .fill(AuraTheme.textSecondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.top, AuraTheme.Spacing.sm)
            .padding(.bottom, AuraTheme.Spacing.xs)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Collapsed

    private var collapsedSummary: some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            AvatarStack(rows: rows)
            if isSoloCrew {
                Text("Waiting for your crew…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
            } else {
                Text(summary.displaySummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up")
                .font(.caption.weight(.bold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .padding(.horizontal, AuraTheme.Spacing.lg)
        .padding(.bottom, AuraTheme.Spacing.sm)
    }

    // MARK: - Expanded

    private var expandedList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isSoloCrew ? "Crew" : summary.displaySummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .padding(.bottom, AuraTheme.Spacing.sm)

            if isSoloCrew {
                emptyState
            } else {
                // Scrolls only when a large crew exceeds the caller's height cap; a small
                // crew sits at natural height with no bounce.
                ScrollView {
                    VStack(spacing: AuraTheme.Spacing.xs) {
                        ForEach(rows) { row in
                            RosterRowView(row: row)
                            if row.id != rows.last?.id {
                                Divider().overlay(AuraTheme.border)
                            }
                        }
                    }
                    .padding(.horizontal, AuraTheme.Spacing.lg)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            Image(systemName: "person.2.wave.2")
                .font(.title2)
                .foregroundStyle(AuraTheme.textSecondary)
            Text("Waiting for your crew…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
            Text("Share your ride code so they can join.")
                .font(.footnote)
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AuraTheme.Spacing.xl)
    }

    @ViewBuilder private var background: some View {
        if AuraTheme.prefersOpaqueSurface(reduceTransparency: reduceTransparency, contrast) {
            AuraTheme.surface
        } else {
            AuraTheme.surface.opacity(0.9).background(.ultraThinMaterial)
        }
    }
}

// MARK: - Roster row

/// A single crew member: avatar (initial in status color), name (with a quiet "YOU"
/// marker for self), a status pill, and the distance label in cockpit numerals.
struct RosterRowView: View {
    let row: RosterRow

    private var initial: String {
        String(row.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var statusColor: Color {
        if row.isSelf { return AuraTheme.textPrimary }
        switch row.status {
        case .riding:   return AuraTheme.accent
        case .stopped:  return AuraTheme.warning
        case .dropped, .awaiting: return AuraTheme.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            avatar
            Text(row.name)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                .lineLimit(1)
            if row.isSelf {
                Text("YOU")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
            Spacer(minLength: AuraTheme.Spacing.sm)
            statusPill
            if let distanceLabel = row.distanceLabel {
                Text(distanceLabel)
                    .font(AuraTheme.Typography.metricCockpit(16, relativeTo: .subheadline))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, AuraTheme.Spacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [row.isSelf ? "\(row.name), you" : row.name]
        parts.append(statusAccessibilityLabel)
        if let distanceLabel = row.distanceLabel, !row.isSelf {
            parts.append(distanceLabel)
        }
        return parts.joined(separator: ", ")
    }

    private var statusAccessibilityLabel: String {
        switch row.status {
        case .riding:   return "riding"
        case .stopped:  return "stopped"
        case .dropped:  return "no signal"
        case .awaiting: return "waiting to start"
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(statusColor)
                .frame(width: 32, height: 32)
            Text(initial)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(avatarTextColor)
        }
    }

    private var avatarTextColor: Color {
        row.isSelf || row.status == .riding ? AuraTheme.onAccent
            : row.status == .stopped ? AuraTheme.onWarning
            : AuraTheme.background
    }

    @ViewBuilder private var statusPill: some View {
        switch row.status {
        case .stopped:
            pill(text: "Stopped", color: AuraTheme.warning, onColor: AuraTheme.onWarning)
        case .dropped:
            pill(text: "No signal", color: AuraTheme.textSecondary.opacity(0.2), onColor: AuraTheme.textSecondary)
        case .awaiting, .riding:
            EmptyView()
        }
    }

    private func pill(text: String, color: Color, onColor: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(onColor)
            .padding(.horizontal, AuraTheme.Spacing.sm)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

// MARK: - Avatar stack (collapsed handle)

/// A leading-edge overlapping stack of up to 4 avatars for the collapsed handle. Purely
/// decorative — the accessibility label lives on the handle's summary text, not here.
private struct AvatarStack: View {
    let rows: [RosterRow]
    private static let maxShown = 4
    private static let diameter: CGFloat = 26
    private static let overlap: CGFloat = 10

    var body: some View {
        let shown = Array(rows.prefix(Self.maxShown))
        HStack(spacing: -Self.overlap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                dot(for: row)
                    .zIndex(Double(shown.count - index))
            }
        }
        .frame(height: Self.diameter)
        .accessibilityHidden(true)
    }

    private func dot(for row: RosterRow) -> some View {
        let color: Color = row.isSelf ? AuraTheme.textPrimary
            : row.status == .riding ? AuraTheme.accent
            : row.status == .stopped ? AuraTheme.warning
            : AuraTheme.textSecondary
        return ZStack {
            Circle()
                .fill(color)
                .frame(width: Self.diameter, height: Self.diameter)
            Circle()
                .strokeBorder(AuraTheme.surface, lineWidth: 2)
                .frame(width: Self.diameter, height: Self.diameter)
            Text(String(row.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(AuraTheme.background)
        }
    }
}

// MARK: - Collapsed-summary derivation

/// Counts derived from the same `[RosterRow]` the list renders — no independent source
/// of truth for "who's riding" vs. "who's stopped".
private struct RosterSummary {
    let riding: Int
    let stopped: Int
    let dropped: Int

    init(rows: [RosterRow]) {
        let others = rows.filter { !$0.isSelf }
        riding = others.filter { $0.status == .riding }.count
        stopped = others.filter { $0.status == .stopped }.count
        dropped = others.filter { $0.status == .dropped || $0.status == .awaiting }.count
    }

    /// "3 riding · 1 stopped" — omits zero-count clauses; falls back to a dropped-only
    /// clause if that's the only signal.
    var displaySummary: String {
        var clauses: [String] = []
        if riding > 0 { clauses.append("\(riding) riding") }
        if stopped > 0 { clauses.append("\(stopped) stopped") }
        if clauses.isEmpty, dropped > 0 { clauses.append("\(dropped) no signal") }
        return clauses.isEmpty ? "Crew" : clauses.joined(separator: " · ")
    }

    var spokenSummary: String { displaySummary }
}

// MARK: - Previews

#Preview("4 riders — mixed status") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "You", isSelf: true, status: .riding, distanceLabel: nil),
        RosterRow(id: UUID(), name: "Priya", isSelf: false, status: .riding, distanceLabel: "0.4 mi ahead"),
        RosterRow(id: UUID(), name: "Marcus", isSelf: false, status: .riding, distanceLabel: "0.1 mi behind"),
        RosterRow(id: UUID(), name: "Devon", isSelf: false, status: .stopped, distanceLabel: "0.6 mi behind")
    ]
    ZStack(alignment: .bottom) {
        AuraTheme.background.ignoresSafeArea()
        VStack {
            Spacer()
            GroupRosterSheet(rows: rows)
                .padding(.horizontal, AuraTheme.Spacing.md)
        }
    }
}

#Preview("4 riders — expanded") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "You", isSelf: true, status: .riding, distanceLabel: nil),
        RosterRow(id: UUID(), name: "Priya", isSelf: false, status: .riding, distanceLabel: "0.4 mi ahead"),
        RosterRow(id: UUID(), name: "Marcus", isSelf: false, status: .riding, distanceLabel: "0.1 mi behind"),
        RosterRow(id: UUID(), name: "Devon", isSelf: false, status: .stopped, distanceLabel: "0.6 mi behind")
    ]
    previewHost(rows: rows, startsExpanded: true)
}

#Preview("Solo — waiting for crew") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "You", isSelf: true, status: .riding, distanceLabel: nil)
    ]
    previewHost(rows: rows, startsExpanded: true)
}

#Preview("One dropped peer") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "You", isSelf: true, status: .riding, distanceLabel: nil),
        RosterRow(id: UUID(), name: "Priya", isSelf: false, status: .riding, distanceLabel: "0.4 mi ahead"),
        RosterRow(id: UUID(), name: "Sam", isSelf: false, status: .dropped, distanceLabel: "no signal")
    ]
    previewHost(rows: rows, startsExpanded: true)
}

@ViewBuilder
private func previewHost(rows: [RosterRow], startsExpanded: Bool) -> some View {
    ZStack(alignment: .bottom) {
        AuraTheme.background.ignoresSafeArea()
        VStack {
            Spacer()
            GroupRosterSheet(rows: rows, startsExpanded: startsExpanded)
                .padding(.horizontal, AuraTheme.Spacing.md)
        }
    }
}
