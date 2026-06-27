// Aura/Widgets/WidgetTimeline.swift
import WidgetKit
import AuraKit

/// One timeline entry: the decoded snapshot (nil → empty state). Shared by both widgets.
/// Explicitly `Sendable` so it crosses into WidgetKit's nonisolated completion handlers
/// cleanly under the target's default-MainActor isolation.
nonisolated struct SnapshotEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Reads the App-Group snapshot the app writes; never fetches. Emits an entry for now plus a
/// week-boundary reset entry so the weekly total self-corrects across the week turnover even
/// if the app stays closed. One instance per widget.
///
/// The three `TimelineProvider` methods are `nonisolated`: this app-extension target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, which would otherwise infer them onto the
/// MainActor and clash with WidgetKit's nonisolated protocol requirements. They touch only
/// nonisolated, `Sendable` package types (`WidgetSnapshotStore`, `WidgetSnapshot`), so
/// `nonisolated` is safe.
nonisolated struct SnapshotProvider: TimelineProvider {
    nonisolated func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample)
    }

    nonisolated func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot: WidgetSnapshot? = context.isPreview
            ? .sample : WidgetSnapshotStore.appGroup().read()
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    nonisolated func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SnapshotEntry>) -> Void
    ) {
        let now = Date()
        guard let snapshot = WidgetSnapshotStore.appGroup().read() else {
            completion(Timeline(entries: [SnapshotEntry(date: now, snapshot: nil)], policy: .atEnd))
            return
        }
        var entries = [SnapshotEntry(date: now, snapshot: snapshot)]
        if snapshot.week.end > now {
            entries.append(SnapshotEntry(date: snapshot.week.end, snapshot: snapshot.weekReset()))
        }
        completion(Timeline(entries: entries, policy: .after(snapshot.week.end)))
    }
}
