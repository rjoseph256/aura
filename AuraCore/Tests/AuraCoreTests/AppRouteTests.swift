import Testing
import Foundation
import AuraCore

struct AppRouteTests {
    private func place(_ id: UUID = UUID(), _ name: String = "Dest") -> Place {
        Place(id: id, name: name, coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
              category: .custom)
    }

    private func route(_ id: UUID = UUID(), geometryCount: Int = 2) -> Route {
        Route(id: id, origin: Coordinate(latitude: 40.44, longitude: -79.99),
              destination: Coordinate(latitude: 40.46, longitude: -79.92), waypoints: [],
              geometry: Array(repeating: Coordinate(latitude: 40.44, longitude: -79.99),
                              count: geometryCount),
              profile: .fastest, distanceMeters: 1000, estimatedDurationSeconds: 300,
              elevationGainMeters: 10)
    }

    @Test func freeRideEqualsItself() {
        let a = AppRoute.freeRide
        let b = AppRoute.freeRide
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func previewEqualByPlaceId() {
        let id = UUID()
        #expect(AppRoute.preview(place(id, "A")) == AppRoute.preview(place(id, "B")))
        #expect(AppRoute.preview(place()) != AppRoute.preview(place()))
    }

    @Test func navigateEqualByRouteAndDestinationId() {
        let r = UUID(); let d = UUID()
        #expect(AppRoute.navigate(route: route(r), destination: place(d))
                == AppRoute.navigate(route: route(r), destination: place(d)))
        // Same route id, different destination id -> not equal.
        #expect(AppRoute.navigate(route: route(r), destination: place(d))
                != AppRoute.navigate(route: route(r), destination: place()))
        // Different route id, same destination id -> not equal.
        #expect(AppRoute.navigate(route: route(), destination: place(d))
                != AppRoute.navigate(route: route(), destination: place(d)))
    }

    @Test func navigateIdentityIgnoresGeometry() {
        let r = UUID()
        let small = AppRoute.navigate(route: route(r, geometryCount: 2), destination: nil)
        let large = AppRoute.navigate(route: route(r, geometryCount: 5000), destination: nil)
        #expect(small == large)
        #expect(small.hashValue == large.hashValue)
    }

    @Test func differentCasesAreUnequal() {
        #expect(AppRoute.freeRide != AppRoute.preview(place()))
        #expect(AppRoute.preview(place()) != AppRoute.navigate(route: route(), destination: nil))
    }

    @Test func historyAndSettingsEqualThemselves() {
        #expect(AppRoute.history == AppRoute.history)
        #expect(AppRoute.settings == AppRoute.settings)
        #expect(AppRoute.history.hashValue == AppRoute.history.hashValue)
        #expect(AppRoute.settings.hashValue == AppRoute.settings.hashValue)
    }

    @Test func historyAndSettingsAreDistinctFromEachOtherAndOthers() {
        #expect(AppRoute.history != AppRoute.settings)
        #expect(AppRoute.history != AppRoute.joinRide)
        #expect(AppRoute.settings != AppRoute.freeRide)
    }

    // MARK: stack(for:) — deep-link → nav path

    @Test func homeLinkMapsToEmptyPath() {
        #expect(AppRoute.stack(for: .home).isEmpty)
    }

    @Test func historyAndSettingsLinksPushThemselves() {
        #expect(AppRoute.stack(for: .history) == [.history])
        #expect(AppRoute.stack(for: .settings) == [.settings])
    }

    @Test func freeRideLinkPushesFreeRide() {
        #expect(AppRoute.stack(for: .freeRide) == [.freeRide])
    }

    @Test func previewLinkPushesPreviewWithSamePlace() {
        let id = UUID()
        #expect(AppRoute.stack(for: .preview(place(id))) == [.preview(place(id))])
    }

    @Test func joinLinkWrapsInGroupRide() {
        let code = JoinCode(rawValue: "7K2Q9FX3")!
        #expect(AppRoute.stack(for: .join(code)) == [.groupRide(.join(code))])
    }
}
