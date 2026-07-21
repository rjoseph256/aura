import Testing
import AuraCore
@testable import AuraKit

@Suite struct HomeMapCameraTests {
    @Test func defaultZoomMatchesLegacySnapshotZoom() {
        #expect(HomeMapCamera.defaultZoom == 12.5)
    }
    @Test func initialCentersOnRiderWhenPresent() {
        let rider = Coordinate(latitude: 37.77, longitude: -122.41)
        let cam = HomeMapCamera.initial(forRider: rider)
        #expect(cam.center == rider)
        #expect(cam.zoom == HomeMapCamera.defaultZoom)
    }
    @Test func initialFallsBackToCuratedCenterWhenRiderNil() {
        #expect(HomeMapCamera.initial(forRider: nil).center == TerrainSnapshotRequest.curatedDefaultCenter)
    }
    @Test func clampBoundsZoomBothWays() {
        #expect(HomeMapCamera(center: .init(latitude: 0, longitude: 0), zoom: 1).clampedZoom().zoom == HomeMapCamera.minZoom)
        #expect(HomeMapCamera(center: .init(latitude: 0, longitude: 0), zoom: 99).clampedZoom().zoom == HomeMapCamera.maxZoom)
    }
    @Test func resetsOnColdLaunchAndPostRideNotOnReturn() {
        #expect(HomeMapCamera.shouldReset(on: .coldLaunch) == true)
        #expect(HomeMapCamera.shouldReset(on: .rideCompleted) == true)
        #expect(HomeMapCamera.shouldReset(on: .returnedToHome) == false)
    }
}
