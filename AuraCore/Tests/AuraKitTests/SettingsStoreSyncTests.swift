import Testing
import Foundation
@testable import AuraKit

@MainActor
struct SettingsStoreSyncTests {
    private func make() -> (SettingsStore, FakeKeyValueStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "sync-\(UUID().uuidString)")!
        let fake = FakeKeyValueStore()
        return (SettingsStore(defaults: defaults, sync: fake), fake, defaults)
    }

    @Test func localChangeMirrorsToKVSExactlyOnce() {
        let (store, fake, _) = make()
        store.units = .metric
        #expect(fake.string(forKey: "units") == "metric")
        #expect(fake.setCounts["units"] == 1)   // proves the counter is wired and mirroring works
    }

    @Test func remoteApplyDoesNotWriteBackToKVS() {
        let (store, fake, _) = make()
        fake.seed("metric", forKey: "units")
        let changed = store.applyRemoteChange(KeyValueChange(keys: ["units"], reason: .server))
        #expect(store.units == .metric)
        #expect(changed == ["units"])
        // The echo guard held: applying a remote value must NOT push a write back to KVS.
        #expect(fake.setCounts["units", default: 0] == 0)
    }

    @Test func initialSyncLetsRemoteWinOverSeededDefaults() {
        let (store, fake, _) = make()
        #expect(store.units == .imperial) // seeded default
        fake.seed("metric", forKey: "units")
        _ = store.applyRemoteChange(KeyValueChange(keys: ["units"], reason: .initialSync))
        #expect(store.units == .metric)
    }

    @Test func onlySyncedKeysCross() {
        #expect(SettingsStore.syncedKeys ==
                ["units", "weeklyGoalMeters", "mapStyle", "voiceEnabled", "turnHaptics"])
        #expect(!SettingsStore.syncedKeys.contains("saveToHealth"))
    }

    @Test func applyReportsChangedKeysForWidgetRefresh() {
        let (store, fake, _) = make()
        fake.seed(50_000.0, forKey: "weeklyGoalMeters")
        let changed = store.applyRemoteChange(KeyValueChange(keys: ["weeklyGoalMeters"], reason: .server))
        #expect(changed.contains("weeklyGoalMeters"))
        #expect(store.weeklyGoalMeters == 50_000)
    }
}
