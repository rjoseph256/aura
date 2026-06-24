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

    /// In-memory recents for v1 (persistence is Plan 4). Most-recent first, de-duped by name+coord, cap ~8.
    private(set) var recents: [Place] = []

    func remember(_ place: Place) {
        recents.removeAll { $0.name == place.name && $0.coordinate == place.coordinate }
        recents.insert(place, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
    }
}
