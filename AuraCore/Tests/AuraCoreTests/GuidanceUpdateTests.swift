import Testing
@testable import AuraCore

@Suite struct GuidanceUpdateTests {
    @Test func newFieldsDefaultToNil() {
        let update = GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn right")
        #expect(update.distanceRemainingMeters == nil)
        #expect(update.durationRemainingSeconds == nil)
        #expect(update.currentStreetName == nil)
    }

    @Test func allFieldsRoundTrip() {
        let update = GuidanceUpdate(
            distanceToManeuverMeters: 100, instruction: "Turn right onto Penn Ave",
            distanceRemainingMeters: 3380, durationRemainingSeconds: 1080,
            currentStreetName: "Penn Ave")
        #expect(update.distanceRemainingMeters == 3380)
        #expect(update.durationRemainingSeconds == 1080)
        #expect(update.currentStreetName == "Penn Ave")
        #expect(update == update)
    }
}
