import WidgetKit
import AuraKit

/// Rebuilds the widget snapshot from the persisted summaries + settings and asks WidgetKit
/// to reload. Called whenever the data the widgets show changes: a ride finishes, a ride is
/// deleted, the weekly goal or units change, and on launch / foreground. The only WidgetKit
/// symbol in the app target.
@MainActor
enum WidgetRefresh {
    private static let store = WidgetSnapshotStore.appGroup()

    static func reload(rideStore: RideStore, settings: SettingsStore,
                       activeRideID: UUID?, now: Date = Date()) {
        let summaries = (try? rideStore.summaries()) ?? []
        let snapshot = WidgetSnapshot.make(summaries: summaries,
                                           goalMeters: settings.weeklyGoalMeters,
                                           units: settings.units, now: now,
                                           activeRideID: activeRideID)
        // The exclusion removed the rider's only ride. Writing this would replace a correct
        // widget with the first-run empty state mid-ride — and the snapshot is a file, so a
        // jetsam kill during the pause freezes that empty state until the app is next opened.
        // Keeping the previous snapshot is stale by one ride instead of wrong.
        if activeRideID != nil, snapshot.lastRide == nil, !summaries.isEmpty { return }
        store.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
