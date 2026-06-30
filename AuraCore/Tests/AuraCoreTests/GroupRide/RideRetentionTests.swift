import Foundation
import Testing
@testable import AuraCore

struct RideRetentionTests {
    @Test func endedRideExpires48hAfterLastActivity() {
        let created = Date(timeIntervalSince1970: 0)
        let ended = created.addingTimeInterval(3600)         // +1h
        let lastActivity = created.addingTimeInterval(1800)  // +30m
        let exp = RideRetention.expiresAt(createdAt: created, endedAt: ended, lastActivity: lastActivity)
        #expect(exp == lastActivity.addingTimeInterval(48 * 3600))
    }
    @Test func neverEndedRideUsesCreationCeiling() {
        let created = Date(timeIntervalSince1970: 0)
        let exp = RideRetention.expiresAt(createdAt: created, endedAt: nil, lastActivity: nil)
        #expect(exp == created.addingTimeInterval(36 * 3600))
    }
}
