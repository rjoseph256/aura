import Testing
import Foundation
@testable import AuraCore

@Suite("Pause control copy")
struct PauseControlCopyTests {
    @Test("The visible label names the action, not the state")
    func buttonLabelNamesTheAction() {
        #expect(PauseControlCopy.buttonLabel(isPaused: false) == "Pause")
        #expect(PauseControlCopy.buttonLabel(isPaused: true) == "Resume")
    }

    @Test("The VoiceOver label tracks state rather than using a toggle value")
    func accessibilityLabelTracksState() {
        // "Pause ride, on" would be ambiguous about whether "on" describes the pause
        // or the ride, so the label itself changes.
        #expect(PauseControlCopy.accessibilityLabel(isPaused: false) == "Pause ride")
        #expect(PauseControlCopy.accessibilityLabel(isPaused: true) == "Resume ride")
    }

    @Test("The transition announcement states the new state in the past tense")
    func announcementStatesTheNewState() {
        #expect(PauseControlCopy.announcement(isPaused: true) == "Ride paused")
        #expect(PauseControlCopy.announcement(isPaused: false) == "Ride resumed")
    }

    @Test("The chip label is a single uppercase word")
    func chipLabel() {
        #expect(PauseControlCopy.stateChipLabel == "PAUSED")
    }

    @Test("The clock renders minutes and seconds under an hour")
    func clockUnderAnHour() {
        #expect(PauseControlCopy.clock(0) == "0:00")
        #expect(PauseControlCopy.clock(9) == "0:09")
        #expect(PauseControlCopy.clock(252) == "4:12")
        #expect(PauseControlCopy.clock(3599) == "59:59")
    }

    @Test("The clock grows an hours field rather than running minutes past 59")
    func clockOverAnHour() {
        #expect(PauseControlCopy.clock(3600) == "1:00:00")
        #expect(PauseControlCopy.clock(7565) == "2:06:05")
    }

    @Test("A negative interval cannot render a negative clock")
    func clockClampsNegative() {
        #expect(PauseControlCopy.clock(-5) == "0:00")
    }

    @Test("The chip's VoiceOver read spells the duration out in words")
    func chipAccessibilityLabel() {
        #expect(PauseControlCopy.chipAccessibilityLabel(pausedSeconds: 252)
                == "Paused for 4 minutes 12 seconds")
        #expect(PauseControlCopy.chipAccessibilityLabel(pausedSeconds: 45)
                == "Paused for 45 seconds")
    }
}
