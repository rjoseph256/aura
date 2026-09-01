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

    /// The ride being recorded, or nil. Written by both HUDs alongside their existing
    /// lifecycle edges.
    var activeRideID: UUID?
    /// Computed, never stored: two stored properties written from four HUD sites can desync,
    /// and a desync means either the in-flight ride leaks back into Home or a finished ride
    /// vanishes from it. Every existing reader — the deep-link guard below,
    /// `LocationAccuracyMode.desired`, Settings' toggles, Home's post-ride reset, and the
    /// backfill cancellation — is unchanged, and observation still propagates because this
    /// getter reads the tracked stored property.
    var isRideActive: Bool { activeRideID != nil }

    func push(_ route: AppRoute) { path.append(route) }
    func pop() { if !path.isEmpty { path.removeLast() } }
    func popToRoot() { path.removeAll() }

    /// Present the finished-ride summary as a pushed route by COLLAPSING the whole path to a
    /// single entry, so only Home sits beneath it (ROH-85). The collapse (and its single-entry
    /// invariant) lives in the pure, unit-tested `RideSummaryRouting.collapsed`. One path write.
    func showRideSummary(_ ride: Ride, saveFailed: Bool) {
        path = RideSummaryRouting.collapsed(ride: ride, saveFailed: saveFailed)
    }

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
        if checkSignedIn() { push(.groupRide(entry)) } else if pendingSignIn == nil { pendingSignIn = entry }
    }
    /// Called by RootView after a successful sign-in.
    func resumePendingGroupRide() {
        guard let entry = pendingSignIn else { return }
        pendingSignIn = nil
        push(.groupRide(entry))
    }
    func cancelPendingGroupRide() { pendingSignIn = nil }

    /// Hand off to a group-ride action FROM a transient entry screen that is itself a pushed
    /// destination (the join-code screen), replacing that screen in the back stack rather than
    /// stacking on top of it. This exists because the caller must not do `dismiss()` + `push()`:
    /// those mutate the same NavigationStack path through two different mechanisms (SwiftUI's
    /// dismiss binding and the router) in one runloop tick, and they reconcile into a pushed but
    /// blank destination — the manual-join dead-end observed on device 2026-07-19. One path write
    /// here cannot race itself. When signed in, the current top (the entry screen) is replaced by
    /// `.groupRide` in a single assignment; back then returns home, not to the join screen. When
    /// signed out, the entry screen is popped and the intent stashed, so sign-in resumes onto a
    /// clean stack via `resumePendingGroupRide()`.
    func replaceTopWithGroupRide(_ entry: GroupRideEntry) {
        if checkSignedIn() {
            if path.isEmpty {
                path = [.groupRide(entry)]
            } else {
                path[path.count - 1] = .groupRide(entry)
            }
        } else if pendingSignIn == nil {
            pendingSignIn = entry
            pop()
        }
    }

    /// Single-write top replacement for transient screens with no auth gate (the join screen).
    /// Same rationale as `replaceTopWithGroupRide`: never dismiss() + push in one tick.
    func replaceTop(with route: AppRoute) {
        if path.isEmpty { path = [route] } else { path[path.count - 1] = route }
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
