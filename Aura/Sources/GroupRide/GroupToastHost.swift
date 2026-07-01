import SwiftUI
import AuraKit

/// Top-anchored, auto-dismissing presenter for group-ride membership toasts.
///
/// Drives itself from an injected, append-only `[GroupToastEvent]` — this task builds the
/// presenter standalone so it previews without a live session; Task 17 wires it to
/// `GroupRideSession.toasts`. A `@State` cursor tracks how many events from the front of the
/// array have already been shown; whenever the array grows, the newest (tail) event is
/// presented and a ~2.5 s timer dismisses it. Already-shown toasts are never re-presented,
/// even if the view is re-created with the same array (the cursor starts at `events.count`).
struct GroupToastHost: View {
    let events: [GroupToastEvent]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Index of the next event in `events` that hasn't been presented yet. Starts at
    /// `events.count` so a host created mid-session doesn't replay history.
    @State private var shownCount: Int
    @State private var visibleEvent: GroupToastEvent?
    /// Bumped on every new toast so the dismiss `.task` for a stale toast can no-op after
    /// a newer one preempts it (`.task(id:)` cancels the old one automatically, but the
    /// stamp also guards the manual dismiss against any race).
    @State private var presentationStamp = 0

    private static let dismissDelay: Duration = .milliseconds(2500)

    init(events: [GroupToastEvent]) {
        self.events = events
        _shownCount = State(initialValue: events.count)
    }

    var body: some View {
        VStack {
            if let visibleEvent {
                toastChip(for: visibleEvent)
                    .transition(toastTransition)
                    .task(id: presentationStamp) {
                        try? await Task.sleep(for: Self.dismissDelay)
                        guard !Task.isCancelled else { return }
                        dismiss()
                    }
            }
            Spacer(minLength: 0)
        }
        .zIndex(10)
        .allowsHitTesting(false)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.22), value: visibleEvent)
        .onChange(of: events.count) { _, newCount in
            presentNext(newCount: newCount)
        }
        .onAppear {
            // In case the view materializes with events already queued past the cursor
            // (e.g. a fast join immediately followed by re-render), catch up to the tail.
            presentNext(newCount: events.count)
        }
    }

    // MARK: - Drain

    /// Presents the tail item once the array has grown past `shownCount`, then advances the
    /// cursor to the full new count (so any events coalesced between renders are treated as
    /// shown — only the very latest is ever displayed, per the brief's "shows the newest").
    private func presentNext(newCount: Int) {
        guard newCount > shownCount, let tail = events.last else { return }
        shownCount = newCount
        visibleEvent = tail
        presentationStamp += 1
    }

    private func dismiss() {
        visibleEvent = nil
    }

    // MARK: - Motion

    private var toastTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        )
    }

    // MARK: - Chip

    private func toastChip(for event: GroupToastEvent) -> some View {
        Text(copy(for: event))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AuraTheme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .padding(.vertical, AuraTheme.Spacing.sm)
            .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast), in: Capsule())
            .overlay(Capsule().strokeBorder(AuraTheme.hairline(contrast)))
            .padding(.top, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(copy(for: event))
    }

    private func copy(for event: GroupToastEvent) -> String {
        switch event {
        case .joined(let name): return "\(name) joined"
        case .left(let name): return "\(name) left"
        case .hostEnded: return "The host ended the group ride"
        }
    }
}

// MARK: - Previews

#Preview("Joined") {
    previewHost(events: [.joined("Priya")])
}

#Preview("Left") {
    previewHost(events: [.joined("Priya"), .left("Priya")])
}

#Preview("Host ended") {
    previewHost(events: [.joined("Priya"), .joined("Marcus"), .hostEnded])
}

@ViewBuilder
private func previewHost(events: [GroupToastEvent]) -> some View {
    ZStack(alignment: .top) {
        AuraTheme.background.ignoresSafeArea()
        GroupToastHost(events: events)
    }
}
