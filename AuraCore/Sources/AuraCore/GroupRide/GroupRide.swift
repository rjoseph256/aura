import Foundation

public struct GroupRide: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable { case active, ended }

    /// Whether the ride has a destination (ROH-114), mirroring the `rides.kind` column.
    ///
    /// The server derives this once, in `create_ride`'s body, and migration 0022 constrains it to
    /// agree with the route column. Everything on the read side carries the **stored** value
    /// rather than re-deriving it from a nil route, so there is one authority for the question
    /// (spec D1.3).
    public enum Kind: String, Codable, Sendable { case route, open }

    public let id: UUID
    public let hostID: UUID
    public let joinCode: JoinCode
    public let kind: Kind
    public let status: Status
    public let createdAt: Date
    public let startedAt: Date?
    public let endedAt: Date?

    /// `kind` has **no default on purpose.** Every field here is a `let`, so lifecycle changes are
    /// expressed as a fresh value, and a defaulted `kind` would let such a rebuild quietly restamp
    /// an open ride as a route ride. Requiring it makes each construction site state what it means;
    /// rebuilds should use `replacing(...)` and not restate anything at all.
    public init(id: UUID, hostID: UUID, joinCode: JoinCode, kind: Kind, status: Status,
                createdAt: Date, startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id; self.hostID = hostID; self.joinCode = joinCode; self.kind = kind
        self.status = status; self.createdAt = createdAt
        self.startedAt = startedAt; self.endedAt = endedAt
    }

    /// A copy with only the named fields changed; everything else — `kind` included — carries
    /// through untouched.
    ///
    /// This exists so no caller has to restate the whole value to advance a ride's lifecycle. The
    /// positional rebuild it replaces was the shape of a live trap: adding `kind` to the type left
    /// four sites that each had to remember to forward it, and forgetting at any one of them turns
    /// a joined open ride into a route ride with no route — the error screen ROH-114 exists to
    /// delete. A field added after this one is carried by every rebuild for free.
    ///
    /// The date parameters are doubly optional so that "leave it alone" (`.none`) stays distinct
    /// from "clear it" (`.some(nil)`); a plain `Date? = nil` could only ever set.
    public func replacing(hostID: UUID? = nil, status: Status? = nil,
                          startedAt: Date?? = .none, endedAt: Date?? = .none) -> GroupRide {
        GroupRide(id: id, hostID: hostID ?? self.hostID, joinCode: joinCode, kind: kind,
                  status: status ?? self.status, createdAt: createdAt,
                  startedAt: startedAt ?? self.startedAt, endedAt: endedAt ?? self.endedAt)
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
