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
    /// remembering a previewed place. A `.join` link goes through the group-ride auth gate
    /// instead of straight onto the path, so an unauthenticated deep link defers to sign-in.
    func handle(url: URL) {
        guard !isRideActive, let link = DeepLink.parse(url) else { return }
        if case let .preview(place) = link { remember(place) }
        if case let .join(code) = link {
            startGroupRide(.join(code))
            return
        }
        path = AppRoute.stack(for: link)
    }

    /// Reads auth state without AppRouter importing AuthStore. Set once at app init (Task 9).
    @ObservationIgnored var checkSignedIn: () -> Bool = { false }

    /// Non-nil while the sign-in sheet is up for a deferred group action. Held here (not in a
    /// view) so the pending intent survives view teardown and the deep-link round trip.
    private(set) var pendingSignIn: GroupRideEntry?

    /// Entry point for every group-ride action. Pushes immediately when signed in; otherwise
    /// stashes the intent and lets RootView drive sign-in. Reentrant-safe: a second call while
    /// one is pending is ignored.
    func startGroupRide(_ entry: GroupRideEntry) {
        if checkSignedIn() { push(.groupRide(entry)) }
        else if pendingSignIn == nil { pendingSignIn = entry }
    }
    /// Called by RootView after a successful sign-in.
    func resumePendingGroupRide() {
        guard let entry = pendingSignIn else { return }
        pendingSignIn = nil
        push(.groupRide(entry))
    }
    func cancelPendingGroupRide() { pendingSignIn = nil }

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
