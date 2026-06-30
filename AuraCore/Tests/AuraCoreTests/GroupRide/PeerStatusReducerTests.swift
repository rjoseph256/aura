import Testing
import Foundation
@testable import AuraCore

struct PeerStatusReducerTests {
    let now = Date(timeIntervalSince1970: 1000)
    func status(_ motion: MotionState?, _ ageSeconds: Double?) -> PeerStatus {
        PeerStatusReducer.status(motionState: motion,
                                 lastUpdate: ageSeconds.map { now.addingTimeInterval(-$0) },
                                 now: now, droppedTimeout: 40)
    }
    @Test func noUpdateYetIsAwaiting() { #expect(status(nil, nil) == .awaiting) }
    @Test func freshMovingIsRiding() { #expect(status(.moving, 2) == .riding) }
    @Test func freshStoppedIsStopped() { #expect(status(.stopped, 2) == .stopped) }
    @Test func staleIsDropped() { #expect(status(.moving, 90) == .dropped) }
    @Test func staleStoppedIsAlsoDropped() { #expect(status(.stopped, 90) == .dropped) }
}
