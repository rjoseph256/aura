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
        #expect(AppRoute.freeRide == AppRoute.freeRide)
        #expect(AppRoute.freeRide.hashValue == AppRoute.freeRide.hashValue)
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
}
