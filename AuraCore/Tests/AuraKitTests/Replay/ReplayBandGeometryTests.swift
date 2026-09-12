import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ReplayBandGeometryTests {
    let g = ReplayBandGeometry(width: 343, thumb: 28, strokeInset: 2)

    @Test func endpointsAreInsetByHalfTheThumbPlusTheStroke() {
        #expect(g.x(0) == 16 && g.x(1) == 327)
        #expect(abs(g.x(0.5) - 171.5) < 1e-9)
    }

    @Test func fractionAtXIsTheInverseAndClamps() {
        for f in stride(from: 0.0, through: 1, by: 0.05) { #expect(abs(g.fraction(atX: g.x(f)) - f) < 1e-12) }
        #expect(g.fraction(atX: -50) == 0 && g.fraction(atX: 999) == 1)
    }

    @Test func degenerateWidthNeverDividesByZero() {
        let tiny = ReplayBandGeometry(width: 10, thumb: 28, strokeInset: 2)
        #expect(tiny.fraction(atX: 5).isFinite && tiny.x(0.5).isFinite)
    }

    @Test func thumbYFollowsTheSilhouetteAndCentersOnTheRail() {
        let rising: [Double] = [0, 10, 20, 30, 40]
        let top = g.thumbY(fraction: 1, samples: rising, height: 88)
        let bottom = g.thumbY(fraction: 0, samples: rising, height: 88)
        #expect(top < bottom)
        let mid = g.thumbY(fraction: 0.5, samples: rising, height: 88)
        #expect(abs(mid - (top + bottom) / 2) < 1e-9)
        #expect(g.thumbY(fraction: 0.3, samples: nil, height: 88) == 44)
    }

    @Test func stripsHaveAMinimumWidth() {
        let narrow = ReplayHold(kind: .paused, seconds: 60, range: 0.5..<0.501)
        let frame = g.stripFrame(narrow)
        #expect(frame.width == 12)
        #expect(abs((frame.x + 6) - (g.x(0.5) + g.x(0.501)) / 2) < 1e-9)
        let wide = ReplayHold(kind: .paused, seconds: 600, range: 0.2..<0.4)
        #expect(abs(g.stripFrame(wide).width - (g.x(0.4) - g.x(0.2))) < 1e-9)
    }

    /// A short hold near either end of the ride would otherwise widen past `x(0)`/`x(1)` — the
    /// farthest the thumb can actually sit — since the naive fix only extends rightward.
    @Test func stripsNearTheEndsStayOnTheTrack() {
        let nearEnd = ReplayHold(kind: .paused, seconds: 60, range: 0.997..<0.9985)
        let endFrame = g.stripFrame(nearEnd)
        #expect(endFrame.width == 12)
        #expect(endFrame.x + endFrame.width <= g.x(1) + 1e-9)

        let nearStart = ReplayHold(kind: .paused, seconds: 60, range: 0.001..<0.002)
        let startFrame = g.stripFrame(nearStart)
        #expect(startFrame.width == 12)
        #expect(startFrame.x >= g.x(0) - 1e-9)
    }

    @Test func captionsDropWhenTheyWouldOverlapAndSkipShortHolds() {
        let holds = [
            ReplayHold(kind: .stopped, seconds: 600, range: 0.10..<0.14),   // caption
            ReplayHold(kind: .stopped, seconds: 300, range: 0.15..<0.18),   // overlaps → dropped
            ReplayHold(kind: .paused, seconds: 60, range: 0.50..<0.52),     // under 120 s → none
            ReplayHold(kind: .signalLost, seconds: 180, range: 0.80..<0.83) // caption
        ]
        let centers = g.captionCenters(holds: holds, captionWidth: 44, minSeconds: 120)
        #expect(centers.map(\.seconds) == [600, 180])
        #expect(abs(centers[0].center - (g.x(0.10) + g.x(0.14)) / 2) < 1e-9)
    }
}

struct ReplayMarkerStyleTests {
    @Test func reduceMotionRoundsToTheEightPointCompass() {
        #expect(ReplayMarkerStyle.displayBearing(100, reduceMotion: true) == 90)
        #expect(ReplayMarkerStyle.displayBearing(113, reduceMotion: true) == 135)
        #expect(ReplayMarkerStyle.displayBearing(113, reduceMotion: false) == 113)
        #expect(ReplayMarkerStyle.displayBearing(nil, reduceMotion: true) == nil)
        #expect(ReplayMarkerStyle.displayBearing(359, reduceMotion: true) == 0)
        #expect(ReplayMarkerStyle.displayBearing(-30, reduceMotion: true) == 315)
        #expect(ReplayMarkerStyle.displayBearing(112.5, reduceMotion: true) == 135)
        #expect(ReplayMarkerStyle.displayBearing(337.5, reduceMotion: true) == 0)
        #expect(ReplayMarkerStyle.displayBearing(360, reduceMotion: true) == 0)
        #expect(ReplayMarkerStyle.displayBearing(-30, reduceMotion: false) == -30)
    }
}
