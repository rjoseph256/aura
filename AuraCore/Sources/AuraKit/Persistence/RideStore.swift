import Foundation
import SwiftData
import AuraCore

@MainActor
public final class RideStore {
    private let container: ModelContainer
    public init(container: ModelContainer) { self.container = container }

    public static func inMemory() throws -> RideStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return RideStore(container: try ModelContainer(for: RideRecord.self, configurations: config))
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
