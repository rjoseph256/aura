import Foundation

/// Pure mirror of the server retention rule. Tracks + membership expire within
/// ~48h of the ride ending (or of last activity for an abandoned ride); a ride
/// with no activity yet uses a 36h creation ceiling.
public enum RideRetention {
    public static func expiresAt(createdAt: Date, endedAt: Date?, lastActivity: Date?) -> Date {
        guard endedAt != nil || lastActivity != nil else {
            return createdAt.addingTimeInterval(36 * 3600)
        }
        let base = (endedAt ?? createdAt).addingTimeInterval(48 * 3600)
        guard let lastActivity else { return base }
        let activityBound = lastActivity.addingTimeInterval(48 * 3600)
        return min(base, activityBound)
    }
}
