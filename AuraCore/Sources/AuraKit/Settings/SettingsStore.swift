import Foundation
import Observation

public enum DistanceUnits: String, Sendable { case imperial, metric }
public enum MapStyle: String, Sendable { case dark, standard }

/// Stored (not computed) properties so the `@Observable` macro actually tracks them —
/// the macro only instruments stored properties, so views reading these through the
/// environment re-render when they change. Each `didSet` mirrors the value into
/// `UserDefaults` for persistence; the initial values are seeded from `UserDefaults`.
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    public var units: DistanceUnits { didSet { defaults.set(units.rawValue, forKey: Key.units) } }
    public var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: Key.voice) } }
    public var mapStyle: MapStyle { didSet { defaults.set(mapStyle.rawValue, forKey: Key.mapStyle) } }
    /// Weekly distance target the home ring fills toward, stored in meters (unit-agnostic).
    public var weeklyGoalMeters: Double { didSet { defaults.set(weeklyGoalMeters, forKey: Key.weeklyGoal) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        units = DistanceUnits(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .imperial
        voiceEnabled = defaults.object(forKey: Key.voice) as? Bool ?? true
        mapStyle = MapStyle(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .dark
        // Default ≈ 40 km / 25 mi. Guard against a corrupt/zero stored value.
        let storedGoal = defaults.object(forKey: Key.weeklyGoal) as? Double
        weeklyGoalMeters = (storedGoal.map { $0 > 0 ? $0 : nil } ?? nil) ?? 40_000
    }

    private enum Key {
        static let units = "units"; static let voice = "voiceEnabled"; static let mapStyle = "mapStyle"
        static let weeklyGoal = "weeklyGoalMeters"
    }
}
