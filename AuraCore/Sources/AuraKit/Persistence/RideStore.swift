import Foundation
import SwiftData
import Observation
import CoreData
import AuraCore

@MainActor
@Observable
public final class RideStore {
    public let container: ModelContainer
    /// True when rides live in a throwaway in-memory store (the on-disk container failed),
    /// so the UI can warn that rides won't persist across launches.
    public let isEphemeral: Bool
    /// Bumps when CloudKit merges a remote change into the store, so views that hold
    /// a fetched snapshot (HistoryView, the dashboard) can refetch. 0 until the first import.
    public private(set) var syncRevision: Int = 0
    // nonisolated(unsafe): NotificationCenter's opaque removal token is inert data — it's
    // only ever passed back to `removeObserver`, never read — so it's safe to touch from
    // the nonisolated `deinit`, which strict concurrency otherwise forbids for a
    // non-Sendable-typed stored property.
    @ObservationIgnored private nonisolated(unsafe) var remoteChangeObserver: NSObjectProtocol?

    public init(container: ModelContainer, isEphemeral: Bool = false) {
        self.container = container
        self.isEphemeral = isEphemeral
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            // Hop to the main actor via Task: the notification closure is @Sendable, so it
            // cannot capture a non-Sendable @MainActor `self` for a synchronous call.
            Task { @MainActor in self?.syncRevision &+= 1 }
        }
    }

    deinit {
        if let remoteChangeObserver { NotificationCenter.default.removeObserver(remoteChangeObserver) }
    }

    public static func inMemory() throws -> RideStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return RideStore(container: try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                                       SeenGemRecord.self,
                                                       configurations: config),
                         isEphemeral: true)
    }

    /// The app's on-disk store, migrated and mirrored to the rider's private CloudKit
    /// database. Same default store URL as before, so existing local rides are found,
    /// migrated, and uploaded on first sync. `inMemory()` stays local.
    public static func persistent() throws -> RideStore {
        let config = ModelConfiguration(cloudKitDatabase: .private("iCloud.com.rohunjoseph.aura"))
        let container = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                           SeenGemRecord.self,
                                           migrationPlan: RideMigrationPlan.self,
                                           configurations: config)
        return RideStore(container: container)
    }

    /// Write a ride, keyed on its id: an existing row is updated in place, anything else is
    /// inserted. Upsert rather than insert because the ride pipeline now writes a checkpoint at
    /// every pause boundary (spec D7) and then the finished ride at End — a blind insert would
    /// leave History holding one copy of the ride per pause.
    ///
    /// **Adding a column to `RideRecord` means adding a line to the update branch below.** It
    /// is a hand-written field copy, not a whole-row replace, and nothing enforces that it is
    /// complete — a column left out here is silently frozen at whatever the first write put in
    /// it. `updatePathCarriesEveryColumn` is the guard; extend it with the column.
    ///
    /// For V6 specifically: `segmentsData` must be copied here, or a ride that was checkpointed
    /// at a pause keeps the segments it had at that pause while `trackData` moves on — and a
    /// read path that prefers `segmentsData` would then show every paused ride truncated at its
    /// first stop. Note also that this is an update path for rides written by *this* build; a
    /// row saved by an older build is still never revisited, so D2's backfill stage stands.
    public func save(_ ride: Ride) throws {
        let context = container.mainContext
        let record = try RideMapper.record(from: ride)
        let id = ride.id
        let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
        if let existing = try context.fetch(descriptor).first {
            existing.kindRaw = record.kindRaw
            existing.startedAt = record.startedAt
            existing.endedAt = record.endedAt
            existing.trackData = record.trackData
            existing.statsData = record.statsData
            existing.distanceMeters = record.distanceMeters
            existing.movingTimeSeconds = record.movingTimeSeconds
            existing.elevationGainMeters = record.elevationGainMeters
            existing.thumbnailData = record.thumbnailData
            existing.destinationName = record.destinationName
            existing.routeId = record.routeId
            existing.destinationPlaceId = record.destinationPlaceId
        } else {
            context.insert(record)
        }
        try context.save()
    }

    public func allRides() throws -> [Ride] {
        let descriptor = FetchDescriptor<RideRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        let rides = try container.mainContext.fetch(descriptor).map { try RideMapper.ride(from: $0) }
        return RideHistoryDedup.unique(rides, by: \.id)
    }

    /// Lightweight, newest-first projection for the list and dashboard. Never reads
    /// `trackData`, so the external blob never faults.
    public func summaries() throws -> [RideSummary] {
        let descriptor = FetchDescriptor<RideRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        let summaries = try container.mainContext.fetch(descriptor).map(RideMapper.summary(from:))
        return RideHistoryDedup.unique(summaries, by: \.id)
    }

    /// The full ride (track + stats), for opening one ride into the detail sheet.
    public func ride(id: UUID) throws -> Ride? {
        let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try container.mainContext.fetch(descriptor).first else { return nil }
        return try RideMapper.ride(from: record)
    }

    public func delete(id: UUID) throws {
        let context = container.mainContext
        let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
        for record in try context.fetch(descriptor) { context.delete(record) }
        try context.save()
    }
}
