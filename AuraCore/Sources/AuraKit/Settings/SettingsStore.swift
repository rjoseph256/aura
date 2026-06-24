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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        units = DistanceUnits(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .imperial
        voiceEnabled = defaults.object(forKey: Key.voice) as? Bool ?? true
        mapStyle = MapStyle(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .dark
    }

    private enum Key { static let units = "units"; static let voice = "voiceEnabled"; static let mapStyle = "mapStyle" }
}
