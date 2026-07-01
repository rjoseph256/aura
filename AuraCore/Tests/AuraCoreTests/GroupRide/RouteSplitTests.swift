import Testing
import AuraCore

struct RouteSplitTests {
    // Three points along the equator, ~111,194.93m apart per segment (haversine),
    // total ~222,389.85m.
    private let line = [
        Coordinate(latitude: 0, longitude: 0),
        Coordinate(latitude: 0, longitude: 1),
        Coordinate(latitude: 0, longitude: 2)
    ]

    @Test func emptyGeometryIsZero() {
        #expect(RouteSplit.splitIndex(geometry: [], atMeters: 500) == 0)
    }

    @Test func singlePointGeometryIsZero() {
        #expect(RouteSplit.splitIndex(geometry: [Coordinate(latitude: 0, longitude: 0)], atMeters: 500) == 0)
    }

    @Test func nonPositiveMetersIsZero() {
        #expect(RouteSplit.splitIndex(geometry: line, atMeters: 0) == 0)
        #expect(RouteSplit.splitIndex(geometry: line, atMeters: -10) == 0)
    }

    @Test func beyondTotalLengthReturnsCount() {
        #expect(RouteSplit.splitIndex(geometry: line, atMeters: 1_000_000) == line.count)
    }

    @Test func midRouteValueReturnsExpectedIndex() {
        // First segment is ~111,194.93m; second brings cumulative to ~222,389.85m.
        // 150,000m falls after point 1 but before point 2 reaches, so the split is at index 2.
        #expect(RouteSplit.splitIndex(geometry: line, atMeters: 150_000) == 2)
    }
}
