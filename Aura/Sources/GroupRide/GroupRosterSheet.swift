import SwiftUI
import AuraCore

/// The crew presence control over the group-ride map (ROH-214): collapsed to a compact
/// circular button in the map-control family — a crew glyph with a rider-count badge that
/// shifts to the warning tint only when a rider has dropped (signal lost; a stopped rider is
/// a red light, not an emergency), and to a quiet neutral while nobody has joined yet — and
/// expanded to the full `RosterRow` card. The old collapsed state was a full-width pill that
/// covered the map right where the eye travels while riding, without earning that space.
/// Pure presentation — every row, count, and label is derived from the `[RosterRow]` this
/// view is handed, so it previews standalone and composes with a live session without
/// knowing about one.
struct GroupRosterSheet: View {
    let rows: [RosterRow]
    /// Shown in the expanded empty state so a host waiting on their crew can actually share
    /// the code — the lobby (the only other place it lives) is gone once the ride starts.
    let joinCode: String?
    /// Selects the empty-state variant: a host sees their code to share, a guest sees the
    /// guest line (every group rider has a `joinCode`, so code-presence alone can't tell
    /// host from guest — role is the only reliable selector).
    let isHost: Bool
    /// Starting detent. Real presentation always starts collapsed (the default);
    /// previews use `true` to show the expanded list without a tap.
    @State private var isExpanded: Bool

    init(rows: [RosterRow], joinCode: String? = nil, isHost: Bool = true, startsExpanded: Bool = false) {
        self.rows = rows
        self.joinCode = joinCode
        self.isHost = isHost
        _isExpanded = State(initialValue: startsExpanded)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var summary: CrewButtonSummary { CrewButtonSummary(rows: rows) }
    private var isSoloCrew: Bool { rows.count <= 1 }

    var body: some View {
        // The collapsed button hugs the leading edge of the cockpit slot the old pill filled;
        // maxWidth keeps this view occupying that flexible slot either way, so the host row's
        // layout (controls pinned trailing) never shifts on toggle.
        ZStack(alignment: .bottomLeading) {
            if isExpanded {
                expandedCard
                    .transition(reduceMotion ? .opacity
                        : .scale(scale: 0.3, anchor: .bottomLeading).combined(with: .opacity))
            } else {
                crewButton
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
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

    // MARK: - Collapsed (compact crew button)

    /// Same drawn-circle/hit-target metrics as the right-side cluster (ROH-75), so the crew
    /// control reads as one more member of the map-control family. The badge carries the
    /// headcount; its tint is a three-state signal: neutral while nobody has joined, accent
    /// for a healthy crew, warning only when a rider has dropped — the one state worth acting
    /// on. Stopped and awaiting stay calm (the review gate showed alarming on them turns the
    /// tint amber at every ride start and every red light).
    private var crewButton: some View {
        Button {
            toggle()
        } label: {
            // Tinted here, inside the label: `HUDControlButton` sets its own foreground on
            // the label from outside, so an outer modifier could never win this one.
            Image(systemName: "person.2.fill")
                .foregroundStyle(summary.needsAttention ? AuraTheme.warning : AuraTheme.textPrimary)
        }
        .buttonStyle(.hudControl(active: false, metrics: .ride))
        .overlay(alignment: .topTrailing) { countBadge }
        .accessibilityLabel("Crew")
        .accessibilityValue(Text(summary.spokenSummary))
        .accessibilityHint("Shows the crew roster.")
    }

    private var badgeTint: (fill: Color, ink: Color) {
        if summary.needsAttention { return (AuraTheme.warning, AuraTheme.onWarning) }
        if summary.isWaitingForCrew { return (AuraTheme.textSecondary, AuraTheme.background) }
        return (AuraTheme.accent, AuraTheme.onAccent)
    }

    private var countBadge: some View {
        Text("\(summary.riderCount)")
            // A text style, not a fixed size, so the one number the collapsed control shows
            // scales with Dynamic Type (the capsule grows with it).
            .font(.system(.caption2, design: .rounded).weight(.bold))
            .monospacedDigit()
            .foregroundStyle(badgeTint.ink)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(badgeTint.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(AuraTheme.background, lineWidth: 1.5))
            // Pull the badge onto the drawn circle's shoulder: the button's frame is the
            // enlarged hit target, whose corner sits (hit − size) / 2 outside the circle.
            .offset(x: -CGFloat(HUDControlMetrics.ride.resolvedHitTarget - HUDControlMetrics.ride.size) / 2,
                    y: CGFloat(HUDControlMetrics.ride.resolvedHitTarget - HUDControlMetrics.ride.size) / 2)
            // Decorative: without this the capsule sits on the circle's shoulder as a dead
            // spot in the ROH-75 tap target (an overlay hit-tests above its base view).
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Expanded card

    private var expandedCard: some View {
        VStack(spacing: 0) {
            collapseHeader
            expandedList
        }
        .padding(.bottom, AuraTheme.Spacing.md)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: AuraTheme.Radius.xl)
                .strokeBorder(AuraTheme.hairline(contrast))
        )
    }

    // MARK: - Collapse header

    /// The whole top of the card — grab handle, summary line, and chevron — is one collapse
    /// control. The first cut made only the 17 pt handle strip tappable and left the chevron
    /// a dead affordance (review-gate finding): the way back to the map deserves at least the
    /// same target the ROH-75 controls get, since collapsing is now the primary interaction.
    private var collapseHeader: some View {
        VStack(spacing: 0) {
            handle
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
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Collapse crew roster")
        .accessibilityValue(Text(summary.spokenSummary))
        .accessibilityAddTraits(.isButton)
    }

    private var handle: some View {
        Capsule()
            .fill(AuraTheme.textSecondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.top, AuraTheme.Spacing.sm)
            .padding(.bottom, AuraTheme.Spacing.xs)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Expanded

    private var expandedList: some View {
        VStack(spacing: 0) {
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

    /// The join code renders right here when the host has one: this card is the only crew
    /// surface left once the ride starts (the lobby is gone), so telling the rider to "share
    /// your ride code" without showing a code was a dead end (review-gate finding). Selected
    /// by role, not code-presence — every group rider has a `joinCode` (gate finding).
    private var emptyState: some View {
        CrewEmptyState(variant: (isHost && joinCode != nil) ? .rosterHost(code: joinCode!) : .rosterGuest)
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
            if row.showsSelfMarker {
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
        var parts = [row.showsSelfMarker ? "\(row.name), you" : row.name]
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

// MARK: - Previews

#Preview("Collapsed button — all riding") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "Jamie Rivera", isSelf: true, status: .riding, distanceLabel: nil),
        RosterRow(id: UUID(), name: "Priya", isSelf: false, status: .riding, distanceLabel: "0.4 mi ahead"),
        RosterRow(id: UUID(), name: "Marcus", isSelf: false, status: .riding, distanceLabel: "0.1 mi behind")
    ]
    previewHost(rows: rows, startsExpanded: false)
}

#Preview("Collapsed button — peer dropped (warning)") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "Jamie Rivera", isSelf: true, status: .riding, distanceLabel: nil),
        RosterRow(id: UUID(), name: "Priya", isSelf: false, status: .riding, distanceLabel: "0.4 mi ahead"),
        RosterRow(id: UUID(), name: "Sam", isSelf: false, status: .dropped, distanceLabel: "no signal")
    ]
    previewHost(rows: rows, startsExpanded: false)
}

#Preview("Collapsed button — solo (waiting)") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "Jamie Rivera", isSelf: true, status: .riding, distanceLabel: nil)
    ]
    previewHost(rows: rows, startsExpanded: false)
}

#Preview("4 riders — expanded") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "Jamie Rivera", isSelf: true, status: .riding, distanceLabel: nil),
        RosterRow(id: UUID(), name: "Priya", isSelf: false, status: .riding, distanceLabel: "0.4 mi ahead"),
        RosterRow(id: UUID(), name: "Marcus", isSelf: false, status: .riding, distanceLabel: "0.1 mi behind"),
        RosterRow(id: UUID(), name: "Devon", isSelf: false, status: .stopped, distanceLabel: "0.6 mi behind")
    ]
    previewHost(rows: rows, startsExpanded: true)
}

#Preview("Solo — waiting for crew") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "Jamie Rivera", isSelf: true, status: .riding, distanceLabel: nil)
    ]
    previewHost(rows: rows, startsExpanded: true)
}

#Preview("Solo — guest waiting for crew") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "Jamie Rivera", isSelf: true, status: .riding, distanceLabel: nil)
    ]
    previewHost(rows: rows, isHost: false, startsExpanded: true)
}

#Preview("One dropped, one awaiting") {
    let rows: [RosterRow] = [
        RosterRow(id: UUID(), name: "Jamie Rivera", isSelf: true, status: .riding, distanceLabel: nil),
        RosterRow(id: UUID(), name: "Priya", isSelf: false, status: .riding, distanceLabel: "0.4 mi ahead"),
        RosterRow(id: UUID(), name: "Sam", isSelf: false, status: .dropped, distanceLabel: "no signal"),
        RosterRow(id: UUID(), name: "Lee", isSelf: false, status: .awaiting, distanceLabel: nil)
    ]
    previewHost(rows: rows, startsExpanded: true)
}

#Preview("Roster — self name not yet resolved") {
    GroupRosterSheet(rows: [
        RosterRow(id: UUID(), name: "You", isSelf: true, status: .riding,
                  distanceLabel: nil, nameResolved: false),
        RosterRow(id: UUID(), name: "Priya", isSelf: false, status: .riding, distanceLabel: "0.4 mi ahead")
    ])
    .preferredColorScheme(.dark)
}

@ViewBuilder
private func previewHost(rows: [RosterRow], isHost: Bool = true, startsExpanded: Bool) -> some View {
    ZStack(alignment: .bottom) {
        AuraTheme.background.ignoresSafeArea()
        VStack {
            Spacer()
            GroupRosterSheet(rows: rows, joinCode: rows.count <= 1 ? "MX4T7Q2A" : nil,
                             isHost: isHost, startsExpanded: startsExpanded)
                .padding(.horizontal, AuraTheme.Spacing.md)
        }
    }
}
