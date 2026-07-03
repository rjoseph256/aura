import SwiftUI
import Observation
import AuraCore

@Observable
@MainActor
final class AppRouter {
    /// The app's single navigation stack, bound by the NavigationStack in RootView. There is
    /// no tab bar — History and Settings are pushed routes reached from the Home control
    /// cluster, so the always-present Home dashboard sheet never buries navigation chrome.
    var path: [AppRoute] = []

    /// True while a ride HUD is recording. The HUDs drive it from `coordinator.isRecording`;
    /// `handle(url:)` reads it so a deep link cannot pop an active ride out from under the rider.
    var isRideActive = false

    func push(_ route: AppRoute) { path.append(route) }
    func pop() { if !path.isEmpty { path.removeLast() } }
    func popToRoot() { path.removeAll() }

    /// Routes an `aura://…` deep link onto the nav path. A recording ride takes precedence:
    /// a URL must never abandon it, so every link is dropped while `isRideActive`. Unknown
    /// links are dropped too, because the parser returns nil for them. The link→path mapping
    /// lives in `AppRoute.stack(for:)` (pure, unit-tested); the only side effect kept here is
    /// remembering a previewed place.
    func handle(url: URL) {
        guard !isRideActive, let link = DeepLink.parse(url) else { return }
        if case let .preview(place) = link { remember(place) }
        path = AppRoute.stack(for: link)
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
