import Foundation
import SwiftData
import Observation
import AuraCore

@MainActor
@Observable
public final class RideStore {
    private let container: ModelContainer
    /// True when rides live in a throwaway in-memory store (the on-disk container failed),
    /// so the UI can warn that rides won't persist across launches.
    public let isEphemeral: Bool

    public init(container: ModelContainer, isEphemeral: Bool = false) {
        self.container = container
        self.isEphemeral = isEphemeral
    }

    public static func inMemory() throws -> RideStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return RideStore(container: try ModelContainer(for: RideRecord.self, configurations: config),
                         isEphemeral: true)
    }

    /// The app's on-disk store, with the migration plan wired in. This is the only
    /// container that migrates; `inMemory()` always starts fresh on the current schema.
    public static func persistent() throws -> RideStore {
        let container = try ModelContainer(for: RideRecord.self,
                                           migrationPlan: RideMigrationPlan.self)
        return RideStore(container: container)
    }

    public func save(_ ride: Ride) throws {
        let context = container.mainContext
        context.insert(try RideMapper.record(from: ride))
        try context.save()
    }

    public func allRides() throws -> [Ride] {
        let descriptor = FetchDescriptor<RideRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try container.mainContext.fetch(descriptor).map { try RideMapper.ride(from: $0) }
    }

    public func delete(id: UUID) throws {
        let context = container.mainContext
        let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
        for record in try context.fetch(descriptor) { context.delete(record) }
        try context.save()
    }
}
