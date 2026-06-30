import Testing
import Foundation
@testable import AuraCore

struct LivePositionTests {
    @Test func payloadRoundTripsThroughCodable() throws {
        let payload = LivePositionPayload(
            userID: UUID(),
            coordinate: Coordinate(latitude: 37.0, longitude: -122.0),
            progressMeters: 123.4,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            motionState: .stopped)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(LivePositionPayload.self, from: data)
        #expect(decoded == payload)
    }
}
