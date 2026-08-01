import Testing
@testable import AuraKit

struct RideTestProbeTests {
    @Test func lineFormatsTruncatedIntegers() {
        #expect(RideTestProbe.line(distanceMeters: 1234.9, elapsed: 45.6,
                                   elevationGainMeters: 12.2,
                                   speedMetersPerSecond: 6.54, segmentCount: 2)
                == "d=1234;e=45;g=12;s=65;n=2")
    }

    @Test func parseRoundTrips() {
        let parsed = RideTestProbe.parse("d=1234;e=45;g=12;s=65;n=2")
        #expect(parsed?.distanceMeters == 1234)
        #expect(parsed?.elapsed == 45)
        #expect(parsed?.elevationGainMeters == 12)
        #expect(parsed?.speedDecimetersPerSecond == 65)
        #expect(parsed?.segmentCount == 2)
    }

    /// A test bundle from this commit against an app binary from before it. `d/e/g` are
    /// required; the two new fields degrade to nil rather than failing the whole parse and
    /// taking the two shipped golden rides down with an unattributable error.
    @Test func parseAcceptsAnOldFormatLine() {
        let parsed = RideTestProbe.parse("d=1234;e=45;g=12")
        #expect(parsed?.distanceMeters == 1234)
        #expect(parsed?.speedDecimetersPerSecond == nil)
        #expect(parsed?.segmentCount == nil)
    }

    @Test func parseRejectsGarbage() {
        #expect(RideTestProbe.parse("hello") == nil)
    }

    @Test func parseRejectsAMissingRequiredField() {
        #expect(RideTestProbe.parse("d=1234;e=45") == nil)
    }
}
