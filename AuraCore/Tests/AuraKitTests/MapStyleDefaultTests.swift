import Testing
import Foundation
@testable import AuraKit

@MainActor
struct MapStyleDefaultTests {
    private func emptyDefaults() -> UserDefaults {
        // A unique suite name yields a fresh, empty domain — no removal needed.
        UserDefaults(suiteName: "MapStyleDefaultTests-\(UUID().uuidString)")!
    }

    @Test func defaultsToAuraTerrainWhenNothingStored() {
        #expect(SettingsStore(defaults: emptyDefaults()).mapStyle == .auraTerrain)
    }

    @Test func keepsAnExplicitStoredChoice() {
        let d = emptyDefaults()
        d.set("dark", forKey: "mapStyle")
        #expect(SettingsStore(defaults: d).mapStyle == .dark)
        d.set("standard", forKey: "mapStyle")
        #expect(SettingsStore(defaults: d).mapStyle == .standard)
    }

    @Test func unknownStoredValueFallsBackToAuraTerrain() {
        let d = emptyDefaults()
        d.set("bogus", forKey: "mapStyle")
        #expect(SettingsStore(defaults: d).mapStyle == .auraTerrain)
    }

    @Test func auraTerrainRoundTripsThroughRawValue() {
        #expect(MapStyle(rawValue: "auraTerrain") == .auraTerrain)
        #expect(MapStyle.auraTerrain.rawValue == "auraTerrain")
    }

    @Test func remoteAuraTerrainAppliesThroughTheSyncPath() {
        let fake = FakeKeyValueStore()
        let store = SettingsStore(defaults: emptyDefaults(), sync: fake)
        store.mapStyle = .dark                       // local diverges from the new default
        fake.seed("auraTerrain", forKey: "mapStyle") // a peer switched to terrain
        let changed = store.applyRemoteChange(KeyValueChange(keys: ["mapStyle"], reason: .server))
        #expect(store.mapStyle == .auraTerrain)
        #expect(changed == ["mapStyle"])
    }
}
