import Testing
import Foundation
@testable import AuraKit

@MainActor
struct ReplayPlaybackTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func pausedFractionIsTheAnchor() {
        let p = ReplayPlayback(playbackDuration: 20)
        #expect(p.fraction(at: t0) == 0 && p.fraction(at: t0 + 100) == 0)
        #expect(p.isPlaying == false)
    }

    @Test func playingAdvancesLinearlyAndClampsBothEnds() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0)
        #expect(p.isPlaying)
        #expect(abs(p.fraction(at: t0 + 5) - 0.25) < 1e-12)
        #expect(p.fraction(at: t0 + 20) == 1 && p.fraction(at: t0 + 99) == 1)
        #expect(p.fraction(at: t0 - 5) == 0)                          // a quantized-down date never goes negative
        #expect(p.hasEnded(at: t0 + 20) && p.hasEnded(at: t0 + 19) == false)
    }

    /// The rule the view must honor: `play` anchors at the date it is GIVEN. A rider who looks
    /// at the paused screen for a minute and then taps Play starts at 0, not at 1.
    @Test func playAfterALongPauseStartsAtZero() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0 + 60)
        #expect(p.fraction(at: t0 + 60) == 0)
        #expect(abs(p.fraction(at: t0 + 65) - 0.25) < 1e-12)
    }

    @Test func pauseFreezesWhereItWas() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.pause(now: t0 + 5)
        #expect(p.isPlaying == false)
        #expect(abs(p.fraction(at: t0 + 50) - 0.25) < 1e-12)
        p.play(now: t0 + 60)
        #expect(abs(p.fraction(at: t0 + 65) - 0.5) < 1e-12)
    }

    @Test func scrubWhilePlayingResumesFromTheScrubbedFraction() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0)
        p.beginScrub(now: t0 + 5)
        #expect(p.isPlaying == false && p.isScrubbing)
        p.scrub(to: 0.8)
        #expect(p.fraction(at: t0 + 6) == 0.8)
        p.endScrub(now: t0 + 7)
        #expect(p.isPlaying && p.isScrubbing == false)
        #expect(abs(p.fraction(at: t0 + 9) - 0.9) < 1e-12)
    }

    @Test func scrubWhilePausedStaysPaused() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.beginScrub(now: t0); p.scrub(to: 0.3); p.endScrub(now: t0 + 1)
        #expect(p.isPlaying == false && p.fraction(at: t0 + 9) == 0.3)
    }

    @Test func scrubToTheEndDoesNotResume() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 1); p.scrub(to: 1); p.endScrub(now: t0 + 2)
        #expect(p.isPlaying == false && p.fraction(at: t0 + 3) == 1)
    }

    /// D4: a tap on the band lands paused at the tapped fraction, whatever was happening.
    @Test func tapWhilePlayingLandsPaused() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 1)
        p.tap(to: 0.4, now: t0 + 1)
        #expect(p.isPlaying == false && p.isScrubbing == false)
        #expect(p.fraction(at: t0 + 30) == 0.4)
        p.tap(to: 1.7, now: t0 + 2)
        #expect(p.fraction(at: t0 + 3) == 1)
    }

    @Test func aSecondBeginScrubDoesNotOverwriteTheResumeIntent() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 1); p.beginScrub(now: t0 + 2)
        p.endScrub(now: t0 + 3)
        #expect(p.isPlaying)
    }

    @Test func cancelScrubClearsTheLatch() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 1); p.cancelScrub()
        #expect(p.isScrubbing == false && p.isPlaying == false)
        p.beginScrub(now: t0 + 5); p.endScrub(now: t0 + 6)
        #expect(p.isPlaying == false)                                 // the old "was playing" did not leak
    }

    @Test func settleParksAtOneAndPlayRestartsFromZero() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.settle()
        #expect(p.isPlaying == false && p.anchorFraction == 1)
        p.play(now: t0 + 40)
        #expect(abs(p.fraction(at: t0 + 45) - 0.25) < 1e-12)
    }

    @Test func togglePlayFlips() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.togglePlay(now: t0); #expect(p.isPlaying)
        p.togglePlay(now: t0 + 2); #expect(p.isPlaying == false)
        #expect(abs(p.fraction(at: t0 + 9) - 0.1) < 1e-12)
    }

    @Test func zeroDurationNeverDividesByZero() {
        let p = ReplayPlayback(playbackDuration: 0)
        p.play(now: t0)
        #expect(p.fraction(at: t0 + 1).isFinite)
    }

    @Test func playWhileScrubbingIsIgnored() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 2); p.scrub(to: 0.4)
        p.play(now: t0 + 3)                                   // second finger on Play mid-drag
        #expect(p.isPlaying == false && p.isScrubbing)
        #expect(abs(p.fraction(at: t0 + 4) - 0.4) < 1e-9)     // still parked where the drag left it
        p.endScrub(now: t0 + 5)                               // the drag's own resume rule still applies
        #expect(p.isPlaying && p.isScrubbing == false)
        #expect(abs(p.fraction(at: t0 + 7) - 0.5) < 1e-9)     // 0.4 + 2 s / 20 s
    }
}
