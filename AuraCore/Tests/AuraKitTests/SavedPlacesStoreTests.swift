import Testing
import Foundation
import SwiftData
import CoreData
@testable import AuraKit
import AuraCore

@MainActor
@Suite("SavedPlacesStore", .swiftDataSerialized)
struct SavedPlacesStoreTests {
    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_000)) throws -> SavedPlacesStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                           configurations: config)
        return SavedPlacesStore(container: container, now: { now })
    }
    private let coordinate = Coordinate(latitude: 40.4406, longitude: -79.9959)

    @Test func saveFetchRoundTrip() throws {
        let store = try makeStore()
        let place = Place(name: "Trace", coordinate: coordinate, category: .brewery)
        guard case let .saved(saved) = store.save(place, subtitle: "Butler St") else {
            Issue.record("expected .saved"); return
        }
        #expect(store.places == [saved])
        #expect(store.isSaved(place))
    }

    @Test func unsaveByJitteredCoordinateRemoves() throws {
        let store = try makeStore()
        _ = store.save(Place(name: "Trace", coordinate: coordinate, category: .brewery),
                       subtitle: nil)
        let jittered = Place(name: "Trace",
                             coordinate: Coordinate(latitude: 40.440601, longitude: -79.995899),
                             category: .brewery)
        store.unsave(jittered)
        #expect(store.places.isEmpty)
    }

    @Test func setHomeOrdersHomeFirstAndReportsDemotion() throws {
        let store = try makeStore()
        guard case let .saved(first) = store.save(
            Place(name: "A", coordinate: coordinate, category: .custom), subtitle: nil),
            case let .saved(second) = store.save(
            Place(name: "B", coordinate: Coordinate(latitude: 40.5, longitude: -80.0),
                  category: .custom), subtitle: nil) else {
            Issue.record("saves failed"); return
        }
        #expect(store.setHome(id: first.id) == false)  // no previous Home
        #expect(store.setHome(id: second.id) == true)  // demotes first
        #expect(store.places.first?.id == second.id)
        #expect(store.places.first?.kind == .home)
        #expect(store.places.last?.kind == .favorite)
    }

    @Test func fullOutcomeAtCap() throws {
        let store = try makeStore()
        for index in 0..<SavedPlacesLogic.maxCount {
            let place = Place(name: "P\(index)",
                              coordinate: Coordinate(latitude: 40 + Double(index) * 0.01,
                                                     longitude: -79.9),
                              category: .custom)
            guard case .saved = store.save(place, subtitle: nil) else {
                Issue.record("save \(index) failed"); return
            }
        }
        let overflow = Place(name: "Overflow",
                             coordinate: Coordinate(latitude: 41.9, longitude: -79.0),
                             category: .custom)
        #expect(store.save(overflow, subtitle: nil) == .full)
    }

    @Test func renameAndDeletePersist() throws {
        let store = try makeStore()
        guard case let .saved(saved) = store.save(
            Place(name: "Old", coordinate: coordinate, category: .custom), subtitle: nil) else {
            Issue.record("save failed"); return
        }
        store.rename(id: saved.id, to: "New")
        #expect(store.places.first?.name == "New")
        store.delete(id: saved.id)
        #expect(store.places.isEmpty)
    }

    @Test func refetchReconcilesInjectedDuplicates() throws {
        // Simulate a CloudKit merge artifact: two records, same rounded key.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                           configurations: config)
        let context = container.mainContext
        context.insert(SavedPlaceRecord(SavedPlace(
            name: "First", subtitle: nil, coordinate: coordinate,
            category: .custom, kind: .favorite,
            savedAt: Date(timeIntervalSince1970: 1))))
        context.insert(SavedPlaceRecord(SavedPlace(
            name: "Second", subtitle: nil,
            coordinate: Coordinate(latitude: 40.440601, longitude: -79.995899),
            category: .custom, kind: .favorite,
            savedAt: Date(timeIntervalSince1970: 9))))
        try context.save()
        let store = SavedPlacesStore(container: container)
        #expect(store.places.count == 1)
        #expect(store.places.first?.name == "Second")
    }

    @Test func remoteChangeNotificationRefetches() async throws {
        // A CloudKit import lands as records the store didn't write, announced
        // by NSPersistentStoreRemoteChange. Mirrors the bounded-poll wait idiom
        // from RideStoreSyncRevisionTests.swift: a single yield is not enough
        // to guarantee the observer's MainActor hop landed.
        //
        // Posts on a private NotificationCenter (not `.default`) because Swift
        // Testing runs suites in parallel: a `.default`-center post with
        // object:nil is delivered to every object:nil observer registered on
        // that center, including RideStore's in RideStoreSyncRevisionTests.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                           configurations: config)
        let center = NotificationCenter()
        let store = SavedPlacesStore(container: container, center: center)
        #expect(store.places.isEmpty)
        container.mainContext.insert(SavedPlaceRecord(SavedPlace(
            name: "Remote", subtitle: nil,
            coordinate: Coordinate(latitude: 40.5, longitude: -80.0),
            category: .custom, kind: .favorite,
            savedAt: Date(timeIntervalSince1970: 5))))
        try container.mainContext.save()
        center.post(name: .NSPersistentStoreRemoteChange, object: nil)
        for _ in 0..<100 where store.places.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.places.first?.name == "Remote")
    }
}
