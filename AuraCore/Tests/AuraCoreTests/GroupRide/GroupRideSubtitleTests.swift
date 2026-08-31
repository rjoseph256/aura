import Testing
import Foundation
@testable import AuraCore

struct GroupRideSubtitleTests {
    @Test func anOpenRideSaysItHasNoDestination() {
        #expect(GroupRideSubtitle.text(kind: .open, placeName: nil, distanceMeters: nil,
                                       isImperial: true) == "No destination — just riding")
    }

    /// An open ride's line must not depend on route data, since by definition it has none — and
    /// must not start naming distances if any leaks through.
    @Test func anOpenRideIgnoresRouteDetailEntirely() {
        #expect(GroupRideSubtitle.text(kind: .open, placeName: "Blue Bottle", distanceMeters: 12_875,
                                       isImperial: true) == "No destination — just riding")
    }

    @Test func aRouteRideNamesThePlaceAndDistance() {
        #expect(GroupRideSubtitle.text(kind: .route, placeName: "Blue Bottle", distanceMeters: 12_875,
                                       isImperial: true) == "Heading to Blue Bottle · 8.0 mi")
    }

    @Test func aRouteRideRespectsMetric() {
        #expect(GroupRideSubtitle.text(kind: .route, placeName: "Blue Bottle", distanceMeters: 12_875,
                                       isImperial: false) == "Heading to Blue Bottle · 12.9 km")
    }

    /// The guest case, and the common one: they joined by typing a code, so they have no `Place`.
    /// The line has to carry information without a name rather than apologise for missing one.
    @Test func aGuestWithNoPlaceNameStillLearnsTheDistance() {
        #expect(GroupRideSubtitle.text(kind: .route, placeName: nil, distanceMeters: 12_875,
                                       isImperial: true) == "8.0 mi route")
    }

    @Test func aRouteRideWithNeitherStillSaysSomethingTrue() {
        #expect(GroupRideSubtitle.text(kind: .route, placeName: nil, distanceMeters: nil,
                                       isImperial: true) == "Heading to the host's destination")
    }

    @Test func aPlaceWithNoDistanceStillNamesIt() {
        #expect(GroupRideSubtitle.text(kind: .route, placeName: "Blue Bottle", distanceMeters: nil,
                                       isImperial: true) == "Heading to Blue Bottle")
    }

    /// Before create/join lands, the lobby is already on screen. Rendering nothing beats guessing
    /// a kind and then contradicting it a moment later.
    @Test func anUnknownKindRendersNothing() {
        #expect(GroupRideSubtitle.text(kind: nil, placeName: "Blue Bottle", distanceMeters: 12_875,
                                       isImperial: true) == nil)
    }

    /// Converts through `UnitConverter`'s exact 1609.344, not `PeerDistance`'s 1609.34. One mile
    /// exactly must read as 1.0, which the coarser divisor also manages — so this pins the
    /// intent rather than the rounding, and documents which divisor this file is on.
    @Test func aSingleMileIsExact() {
        #expect(GroupRideSubtitle.text(kind: .route, placeName: nil, distanceMeters: 1609.344,
                                       isImperial: true) == "1.0 mi route")
    }
}
