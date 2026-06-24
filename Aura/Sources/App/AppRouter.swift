import SwiftUI
import Observation
import AuraCore

@Observable
@MainActor
final class AppRouter {
    enum Screen: Equatable {
        case plan
        case preview(destination: Place)
        case ride(route: Route?, destination: Place?)   // nil route => free ride
    }
    var screen: Screen = .plan

    /// Selected tab on the plan screen (bound by `AuraTabView`). Lets the home
    /// dashboard switch to History when the rider taps their last ride.
    enum Tab: Hashable { case ride, history, settings }
    var selectedTab: Tab = .ride

    /// Most-recent-first, de-duped by name+coord, cap ~8. Persisted across launches.
    private(set) var recents: [Place] = []

    @ObservationIgnored private let defaults: UserDefaults
    private static let recentsKey = "recentsPlaces"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recentsKey),
           let decoded = try? JSONDecoder().decode([Place].self, from: data) {
            recents = decoded
        }
    }

    func remember(_ place: Place) {
        recents.removeAll { $0.name == place.name && $0.coordinate == place.coordinate }
        recents.insert(place, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        persistRecents()
    }

    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: Self.recentsKey)
        }
    }
}
