import XCTest
@testable import AuraKit

// MARK: - the connectivity caption

@MainActor
final class ShareUpgradeCopyTests: XCTestCase {

    func testTheCaptionIsWithheldUntilARiderTapHasFailed() {
        let terminal = ShareUpgradePhase.unavailable(.freshAttempt)
        XCTAssertNil(ShareUpgradeCopy.caption(for: terminal, hasFailedARiderTap: false),
                     "the first offer stands alone; the rider has not tried anything yet")
        XCTAssertEqual(ShareUpgradeCopy.caption(for: terminal, hasFailedARiderTap: true),
                       ShareUpgradeCopy.connectivityHint)
    }

    func testTheCaptionNeverShowsOutsideATerminalOffer() {
        for phase: ShareUpgradePhase in [.idle, .upgrading, .upgradingVisible,
                                         .upgraded(confirming: true), .upgraded(confirming: false)] {
            XCTAssertNil(ShareUpgradeCopy.caption(for: phase, hasFailedARiderTap: true),
                         "\(phase) shows no offer, so it can carry no caption for one")
        }
    }

    func testBothRetryabilitiesCarryTheCaption() {
        for retryability: Retryability in [.freshAttempt, .mayRejoin] {
            XCTAssertEqual(
                ShareUpgradeCopy.caption(for: .unavailable(retryability), hasFailedARiderTap: true),
                ShareUpgradeCopy.connectivityHint,
                "both render the same live offer, so both earn the same caption")
        }
    }

    func testAFailedTapDoesNotAnnounceLikeASuccessfulOne() {
        let failed = ShareUpgradeCopy.announcement(for: .unavailable(.mayRejoin),
                                                   hasFailedARiderTap: true)
        let succeeded = ShareUpgradeCopy.announcement(for: .upgraded(confirming: true),
                                                      hasFailedARiderTap: true)
        XCTAssertNotNil(failed)
        XCTAssertNotEqual(failed, succeeded)
        XCTAssertEqual(succeeded, ShareUpgradeCopy.confirmation)
    }

    /// The row and the announcement must agree, or a VoiceOver rider and a sighted rider are told
    /// different things about the same state.
    func testTheAnnouncementCarriesTheHintExactlyWhenTheCaptionDoes() {
        for hasFailed in [true, false] {
            let phase = ShareUpgradePhase.unavailable(.freshAttempt)
            let announced = ShareUpgradeCopy.announcement(for: phase, hasFailedARiderTap: hasFailed)
            let captioned = ShareUpgradeCopy.caption(for: phase, hasFailedARiderTap: hasFailed)
            XCTAssertEqual(announced?.contains(ShareUpgradeCopy.connectivityHint), captioned != nil)
        }
    }

    func testNonTerminalPhasesAnnounceNothing() {
        for phase: ShareUpgradePhase in [.idle, .upgrading, .upgradingVisible] {
            XCTAssertNil(ShareUpgradeCopy.announcement(for: phase, hasFailedARiderTap: true))
        }
    }
}
