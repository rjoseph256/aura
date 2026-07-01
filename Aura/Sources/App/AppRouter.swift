import SwiftUI
import Observation
import AuraCore

@Observable
@MainActor
final class AppRouter {
    /// Selected tab on the plan screen (bound by the Ride tab's NavigationStack). Lets the home
    /// dashboard switch to History when the rider taps their last ride.
    enum Tab: Hashable { case ride, history, settings }
    var selectedTab: Tab = .ride

    /// The Ride tab's navigation stack, bound by the NavigationStack in RootView.
    var path: [AppRoute] = []

    /// True while a ride HUD is recording. The HUDs drive it from `coordinator.isRecording`;
    /// `handle(url:)` reads it so a deep link cannot pop an active ride out from under the rider.
    var isRideActive = false

    func push(_ route: AppRoute) { path.append(route) }
    func pop() { if !path.isEmpty { path.removeLast() } }
    func popToRoot() { path.removeAll() }

    /// Routes an `aura://…` deep link to the tab and path. A recording ride takes precedence:
    /// a URL must never abandon it, so every link is dropped while `isRideActive`. Unknown
    /// links are dropped too, because the parser returns nil for them.
    func handle(url: URL) {
        guard !isRideActive, let link = DeepLink.parse(url) else { return }
        switch link {
        case .home:
            selectedTab = .ride
            path.removeAll()
        case .history:
            selectedTab = .history
        case .settings:
            selectedTab = .settings
        case .freeRide:
            selectedTab = .ride
            path = [.freeRide]
        case let .preview(place):
            remember(place)
            selectedTab = .ride
            path = [.preview(place)]
        case let .join(code):
            selectedTab = .ride
            path = [.groupRide(.join(code))]
        }
    }

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
