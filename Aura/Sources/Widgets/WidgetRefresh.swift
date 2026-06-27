import WidgetKit
import AuraKit

/// Rebuilds the widget snapshot from the persisted summaries + settings and asks WidgetKit
/// to reload. Called whenever the data the widgets show changes: a ride finishes, a ride is
/// deleted, the weekly goal or units change, and on launch / foreground. The only WidgetKit
/// symbol in the app target.
@MainActor
enum WidgetRefresh {
    private static let store = WidgetSnapshotStore.appGroup()

    static func reload(rideStore: RideStore, settings: SettingsStore, now: Date = Date()) {
        let summaries = (try? rideStore.summaries()) ?? []
        let snapshot = WidgetSnapshot.make(summaries: summaries,
                                           goalMeters: settings.weeklyGoalMeters,
                                           units: settings.units, now: now)
        store.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
