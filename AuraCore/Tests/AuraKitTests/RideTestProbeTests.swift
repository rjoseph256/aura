import Testing
@testable import AuraKit

struct RideTestProbeTests {
    @Test func lineFormatsTruncatedIntegers() {
        #expect(RideTestProbe.line(distanceMeters: 1234.9, elapsed: 45.6, elevationGainMeters: 12.2)
                == "d=1234;e=45;g=12")
    }

    @Test func parseRoundTrips() {
        let parsed = RideTestProbe.parse("d=1234;e=45;g=12")
        #expect(parsed?.distanceMeters == 1234)
        #expect(parsed?.elapsed == 45)
        #expect(parsed?.elevationGainMeters == 12)
    }

    @Test func parseRejectsGarbage() {
        #expect(RideTestProbe.parse("hello") == nil)
    }
}
