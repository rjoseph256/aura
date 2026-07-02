import Testing
@testable import AuraKit

@Suite struct HomeModeTests {
    @Test func trueFirstRun_notOnboardedNoRidesUndetermined() {
        #expect(HomeMode.resolve(hasCompletedOnboarding: false, hasRides: false, auth: .notDetermined) == .firstRun)
    }
    @Test func returningUserDeniedLocationNoRides_isPopulated() {
        // The spec's "no location permission (returning user)" case must NOT get first-run.
        #expect(HomeMode.resolve(hasCompletedOnboarding: true, hasRides: false, auth: .denied) == .populated)
    }
    @Test func anyRides_isPopulated() {
        #expect(HomeMode.resolve(hasCompletedOnboarding: false, hasRides: true, auth: .notDetermined) == .populated)
    }
    @Test func onboardedNoRidesUndetermined_isPopulated() {
        #expect(HomeMode.resolve(hasCompletedOnboarding: true, hasRides: false, auth: .notDetermined) == .populated)
    }
}
