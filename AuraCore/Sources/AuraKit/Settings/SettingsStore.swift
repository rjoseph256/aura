import Foundation
import Observation

public enum DistanceUnits: String, Codable, Hashable, Sendable { case imperial, metric }
public enum MapStyle: String, Sendable { case dark, standard }

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

    public init(defaults: UserDefaults = .standard, sync: KeyValueSyncing? = nil) {
        self.defaults = defaults
        self.sync = sync
        units = DistanceUnits(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .imperial
        voiceEnabled = defaults.object(forKey: Key.voice) as? Bool ?? true
        mapStyle = MapStyle(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .dark
        // Default ≈ 40 km / 25 mi. Guard against a corrupt/zero stored value.
        let storedGoal = defaults.object(forKey: Key.weeklyGoal) as? Double
        weeklyGoalMeters = (storedGoal.map { $0 > 0 ? $0 : nil } ?? nil) ?? 40_000
        saveToHealth = defaults.object(forKey: Key.saveToHealth) as? Bool ?? false
        turnHaptics = defaults.object(forKey: Key.turnHaptics) as? Bool ?? true
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
            switch key {
            case Key.units:
                if let raw = sync.string(forKey: key), let v = DistanceUnits(rawValue: raw), v != units {
                    units = v; changed.insert(key)
                }
            case Key.mapStyle:
                if let raw = sync.string(forKey: key), let v = MapStyle(rawValue: raw), v != mapStyle {
                    mapStyle = v; changed.insert(key)
                }
            case Key.voice:
                if let v = sync.bool(forKey: key), v != voiceEnabled { voiceEnabled = v; changed.insert(key) }
            case Key.turnHaptics:
                if let v = sync.bool(forKey: key), v != turnHaptics { turnHaptics = v; changed.insert(key) }
            case Key.weeklyGoal:
                if let v = sync.double(forKey: key), v > 0, v != weeklyGoalMeters {
                    weeklyGoalMeters = v; changed.insert(key)
                }
            default: break
            }
        }
        return changed
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
    }
}
