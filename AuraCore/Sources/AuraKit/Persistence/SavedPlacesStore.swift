import Foundation
import SwiftData
import Observation
import CoreData
import AuraCore

/// Saved destinations over the app's SwiftData container. All invariants are
/// `SavedPlacesLogic`; this class only fetches, maps, and persists. Mirrors
/// `RideStore`'s remote-change observer so a CloudKit import refreshes rows.
@MainActor
@Observable
public final class SavedPlacesStore {
    public enum SaveOutcome: Equatable {
        case saved(SavedPlace)
        case full
    }

    public private(set) var places: [SavedPlace] = []

    private let container: ModelContainer
    @ObservationIgnored private let now: () -> Date
    // Same shape and rationale as RideStore.remoteChangeObserver.
    @ObservationIgnored private nonisolated(unsafe) var remoteChangeObserver: NSObjectProtocol?

    public init(container: ModelContainer, now: @escaping () -> Date = Date.init) {
        self.container = container
        self.now = now
        refetch()
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refetch() }
        }
    }

    deinit {
        if let remoteChangeObserver { NotificationCenter.default.removeObserver(remoteChangeObserver) }
    }

    public func refetch() {
        let descriptor = FetchDescriptor<SavedPlaceRecord>()
        let values = (try? container.mainContext.fetch(descriptor))?.compactMap(\.value) ?? []
        places = SavedPlacesLogic.reconciled(values)
    }

    public func savedPlace(for place: Place) -> SavedPlace? {
        SavedPlacesLogic.saved(matching: place, in: places)
    }

    public func isSaved(_ place: Place) -> Bool {
        savedPlace(for: place) != nil
    }

    @discardableResult
    public func save(_ place: Place, subtitle: String?) -> SaveOutcome {
        switch SavedPlacesLogic.add(place, subtitle: subtitle, to: places, now: now()) {
        case .full:
            return .full
        case let .added(list):
            persist(list)
            guard let saved = savedPlace(for: place) else {
                assertionFailure("save persisted but lookup missed")
                return .full
            }
            return .saved(saved)
        }
    }

    public func unsave(_ place: Place) {
        guard let saved = savedPlace(for: place) else { return }
        persist(SavedPlacesLogic.remove(id: saved.id, from: places))
    }

    public func delete(id: UUID) {
        persist(SavedPlacesLogic.remove(id: id, from: places))
    }

    public func rename(id: UUID, to name: String) {
        persist(SavedPlacesLogic.rename(id: id, to: name, in: places))
    }

    /// Returns true when a previous Home was demoted (drives confirmation copy).
    @discardableResult
    public func setHome(id: UUID) -> Bool {
        let hadHome = places.contains { $0.kind == .home && $0.id != id }
        persist(SavedPlacesLogic.setHome(id: id, in: places, now: now()))
        return hadHome
    }

    public func removeHome(id: UUID) {
        persist(SavedPlacesLogic.removeHome(id: id, in: places))
    }

    /// Writes the reconciled list as the record set: upsert by id, delete the
    /// rest. ≤ 50 rows, so full-set sync is simpler than diffing.
    private func persist(_ list: [SavedPlace]) {
        let reconciled = SavedPlacesLogic.reconciled(list)
        let context = container.mainContext
        do {
            let records = try context.fetch(FetchDescriptor<SavedPlaceRecord>())
            var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for value in reconciled {
                if let record = byID.removeValue(forKey: value.id) {
                    record.name = value.name
                    record.subtitle = value.subtitle
                    record.latitude = value.coordinate.latitude
                    record.longitude = value.coordinate.longitude
                    record.categoryRaw = value.category.rawValue
                    record.kindRaw = value.kind.rawValue
                    record.savedAt = value.savedAt
                } else {
                    context.insert(SavedPlaceRecord(value))
                }
            }
            for leftover in byID.values where leftover.value != nil {
                // Unknown-raw records (newer app version) are left untouched.
                context.delete(leftover)
            }
            try context.save()
            places = reconciled
        } catch {
            assertionFailure("SavedPlacesStore persist failed: \(error)")
            refetch()
        }
    }
}
