import Foundation
import Observation

public enum DistanceUnits: String, Sendable { case imperial, metric }
public enum MapStyle: String, Sendable { case dark, standard }

@Observable
public final class SettingsStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var units: DistanceUnits {
        get { DistanceUnits(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .imperial }
        set { defaults.set(newValue.rawValue, forKey: Key.units) }
    }
    public var voiceEnabled: Bool {
        get { defaults.object(forKey: Key.voice) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.voice) }
    }
    public var mapStyle: MapStyle {
        get { MapStyle(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .dark }
        set { defaults.set(newValue.rawValue, forKey: Key.mapStyle) }
    }

    private enum Key { static let units = "units"; static let voice = "voiceEnabled"; static let mapStyle = "mapStyle" }
}
