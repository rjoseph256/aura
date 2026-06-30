import Testing
import Foundation
@testable import AuraCore

struct MotionClassifierTests {
    let clf = MotionClassifier(stoppedSpeed: 0.5, stoppedDuration: 18)
    let now = Date(timeIntervalSince1970: 1000)

    @Test func sustainedLowSpeedIsStopped() {
        let samples = (0...20).map { SpeedSample(speed: 0.1, at: now.addingTimeInterval(Double(-$0))) }
        #expect(clf.classify(samples, now: now) == .stopped)
    }
    @Test func aFastSampleInWindowIsMoving() {
        var samples = (0...20).map { SpeedSample(speed: 0.1, at: now.addingTimeInterval(Double(-$0))) }
        samples.append(SpeedSample(speed: 6.0, at: now.addingTimeInterval(-5)))
        #expect(clf.classify(samples, now: now) == .moving)
    }
    @Test func shortLowWindowIsStillMoving() {
        // only 5s of low-speed coverage, less than stoppedDuration -> not yet stopped
        let samples = (0...5).map { SpeedSample(speed: 0.1, at: now.addingTimeInterval(Double(-$0))) }
        #expect(clf.classify(samples, now: now) == .moving)
    }
    @Test func noSamplesIsMoving() {
        #expect(clf.classify([], now: now) == .moving)
    }
}
