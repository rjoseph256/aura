import Foundation
import Observation

public enum DistanceUnits: String, Codable, Hashable, Sendable { case imperial, metric }
public enum MapStyle: String, Sendable { case auraTerrain, dark, standard }

/// Stored (not computed) properties so `@Observable` tracks them. Each `didSet` mirrors
/// the value into `UserDefaults` (source of truth for a launch) and, for the synced keys,
/// into the injected `KeyValueSyncing` (iCloud). Applying a remote change sets the flag so
/// the `didSet` KVS write is suppressed, breaking the didSet -> KVS -> notify -> didSet echo.
/// `@MainActor` because remote changes arrive off-thread and mutate `@Observable` state.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sync: KeyValueSyncing?
    @ObservationIgnored private var isApplyingRemote = false

    public static let syncedKeys: Set<String> =
        [Key.units, Key.weeklyGoal, Key.mapStyle, Key.voice, Key.turnHaptics]

    public var units: DistanceUnits { didSet { persist(units.rawValue, Key.units) } }
    public var voiceEnabled: Bool { didSet { persist(voiceEnabled, Key.voice) } }
    public var mapStyle: MapStyle { didSet { persist(mapStyle.rawValue, Key.mapStyle) } }
    /// Weekly distance target the home ring fills toward, stored in meters (unit-agnostic).
    public var weeklyGoalMeters: Double { didSet { persist(weeklyGoalMeters, Key.weeklyGoal) } }
    /// Opt-in: play a haptic on turn approach and arrival during a navigated ride.
    public var turnHaptics: Bool { didSet { persist(turnHaptics, Key.turnHaptics) } }
    /// Opt-in: write finished rides to Apple Health as cycling workouts.
    /// Device-local: bound to per-device HealthKit auth, so it is not synced.
    public var saveToHealth: Bool { didSet { defaults.set(saveToHealth, forKey: Key.saveToHealth) } }
    /// Device-local: whether the rider has completed the first-run composition. Not synced.
    public var didCompleteOnboarding: Bool { didSet { defaults.set(didCompleteOnboarding, forKey: Key.didCompleteOnboarding) } }

    public init(defaults: UserDefaults = .standard, sync: KeyValueSyncing? = nil) {
        self.defaults = defaults
        self.sync = sync
        units = DistanceUnits(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .imperial
        voiceEnabled = defaults.object(forKey: Key.voice) as? Bool ?? true
        mapStyle = MapStyle(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .auraTerrain
        // Default ≈ 40 km / 25 mi. Guard against a corrupt/zero stored value.
        let storedGoal = defaults.object(forKey: Key.weeklyGoal) as? Double
        weeklyGoalMeters = (storedGoal.map { $0 > 0 ? $0 : nil } ?? nil) ?? 40_000
        saveToHealth = defaults.object(forKey: Key.saveToHealth) as? Bool ?? false
        turnHaptics = defaults.object(forKey: Key.turnHaptics) as? Bool ?? true
        // `bool(forKey:)` (not `object as? Bool`) so a value seeded via the launch argument
        // `-auraDidCompleteOnboarding YES` — which lands in NSArgumentDomain as the STRING
        // "YES" — is coerced to true for UI tests; absent still reads false.
        didCompleteOnboarding = defaults.bool(forKey: Key.didCompleteOnboarding)
    }

    /// The external-change stream from the injected sync store (empty if none).
    public var kvSyncStream: AsyncStream<KeyValueChange> {
        sync?.externalChanges ?? AsyncStream { $0.finish() }
    }

    /// Apply an external iCloud change for the synced keys. Returns the keys whose value
    /// actually changed (the app uses this to decide whether to refresh the widgets).
    /// On `.initialSync`, remote wins over the just-seeded local defaults.
    @discardableResult
    public func applyRemoteChange(_ change: KeyValueChange) -> Set<String> {
        guard let sync else { return [] }
        if change.reason == .quotaViolation { return [] }
        let keys = change.keys.isEmpty ? Array(Self.syncedKeys) : change.keys
        var changed: Set<String> = []
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for key in keys where Self.syncedKeys.contains(key) {
            if applyRemoteKey(key, from: sync) { changed.insert(key) }
        }
        return changed
    }

    /// Applies one synced key's remote value; returns true if the local value changed.
    /// Split per key so each guard stays simple (keeps the dispatch flat, not complex).
    private func applyRemoteKey(_ key: String, from sync: KeyValueSyncing) -> Bool {
        switch key {
        case Key.units: return applyRemoteUnits(sync)
        case Key.mapStyle: return applyRemoteMapStyle(sync)
        case Key.voice: return applyRemoteVoice(sync)
        case Key.turnHaptics: return applyRemoteTurnHaptics(sync)
        case Key.weeklyGoal: return applyRemoteWeeklyGoal(sync)
        default: return false
        }
    }

    private func applyRemoteUnits(_ sync: KeyValueSyncing) -> Bool {
        guard let raw = sync.string(forKey: Key.units),
              let v = DistanceUnits(rawValue: raw), v != units else { return false }
        units = v; return true
    }

    private func applyRemoteMapStyle(_ sync: KeyValueSyncing) -> Bool {
        guard let raw = sync.string(forKey: Key.mapStyle),
              let v = MapStyle(rawValue: raw), v != mapStyle else { return false }
        mapStyle = v; return true
    }

    private func applyRemoteVoice(_ sync: KeyValueSyncing) -> Bool {
        guard let v = sync.bool(forKey: Key.voice), v != voiceEnabled else { return false }
        voiceEnabled = v; return true
    }

    private func applyRemoteTurnHaptics(_ sync: KeyValueSyncing) -> Bool {
        guard let v = sync.bool(forKey: Key.turnHaptics), v != turnHaptics else { return false }
        turnHaptics = v; return true
    }

    private func applyRemoteWeeklyGoal(_ sync: KeyValueSyncing) -> Bool {
        guard let v = sync.double(forKey: Key.weeklyGoal), v > 0, v != weeklyGoalMeters else { return false }
        weeklyGoalMeters = v; return true
    }

    private func persist(_ value: String, _ key: String) {
        defaults.set(value, forKey: key)
        if !isApplyingRemote, Self.syncedKeys.contains(key) { sync?.set(value, forKey: key); sync?.synchronize() }
    }
    private func persist(_ value: Double, _ key: String) {
        defaults.set(value, forKey: key)
        if !isApplyingRemote, Self.syncedKeys.contains(key) { sync?.set(value, forKey: key); sync?.synchronize() }
    }
    private func persist(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
        if !isApplyingRemote, Self.syncedKeys.contains(key) { sync?.set(value, forKey: key); sync?.synchronize() }
    }

    private enum Key {
        static let units = "units"; static let voice = "voiceEnabled"; static let mapStyle = "mapStyle"
        static let weeklyGoal = "weeklyGoalMeters"
        static let saveToHealth = "saveToHealth"
        static let turnHaptics = "turnHaptics"
        static let didCompleteOnboarding = "auraDidCompleteOnboarding"
    }
}
