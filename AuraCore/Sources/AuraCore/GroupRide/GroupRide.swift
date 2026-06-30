import Foundation

public struct GroupRide: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable { case active, ended }
    public let id: UUID
    public let hostID: UUID
    public let joinCode: JoinCode
    public let status: Status
    public let createdAt: Date
    public init(id: UUID, hostID: UUID, joinCode: JoinCode, status: Status, createdAt: Date) {
        self.id = id; self.hostID = hostID; self.joinCode = joinCode
        self.status = status; self.createdAt = createdAt
    }
}

public struct RideMember: Equatable, Codable, Sendable {
    public enum Role: String, Codable, Sendable { case host, member }
    public let userID: UUID
    public let displayName: String
    public let role: Role
    public let lastSeenAt: Date?
    public init(userID: UUID, displayName: String, role: Role, lastSeenAt: Date?) {
        self.userID = userID; self.displayName = displayName
        self.role = role; self.lastSeenAt = lastSeenAt
    }
}

public struct RemoteTrackPoint: Equatable, Codable, Sendable {
    public let userID: UUID
    public let coordinate: Coordinate
    public let recordedAt: Date
    public let progressMeters: Double
    public init(userID: UUID, coordinate: Coordinate, recordedAt: Date, progressMeters: Double) {
        self.userID = userID; self.coordinate = coordinate
        self.recordedAt = recordedAt; self.progressMeters = progressMeters
    }
}
