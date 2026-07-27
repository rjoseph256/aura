import Testing

/// Process-wide serialization gate for tests that build SwiftData `ModelContainer`s.
///
/// Two entities in this store each exist as two `@Model` classes sharing one CoreData entity
/// name:
///
/// - `SavedPlaceRecord` — `RideSchemaV3`'s (no `resurface`) and `RideSchemaV5`'s (adds it).
/// - `RideRecord` — `RideSchemaV2`'s (V2 through V5) and `RideSchemaV6`'s, which adds
///   `segmentsData` and `pausedSeconds`.
///
/// CoreData caches entity descriptions **process-globally by entity name**, so if two
/// containers pinning different versions are alive at once (e.g. a migration suite running
/// concurrently with any current-schema container suite), an object can bind to the wrong
/// version and touching the newer property crashes the whole process with
/// `setValue:forUndefinedKey:`.
///
/// Swift Testing's `.serialized` only serializes tests *within* a suite. This gate serializes
/// every adopting suite against every other adopting suite across the whole run. See ROH-65.
actor SwiftDataSerialGate {
    static let shared = SwiftDataSerialGate()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// A test/suite trait that runs each adopting test while holding ``SwiftDataSerialGate``, so no
/// two container-building suites execute concurrently. Apply with `.swiftDataSerialized`.
///
/// It is a Swift Testing `SuiteTrait`, so an `XCTestCase` cannot adopt it — a suite that builds
/// containers must be written in Swift Testing (see `RideStoreTests`, converted for this).
struct SwiftDataSerialized: TestTrait, SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        await SwiftDataSerialGate.shared.lock()
        do {
            try await function()
        } catch {
            await SwiftDataSerialGate.shared.unlock()
            throw error
        }
        await SwiftDataSerialGate.shared.unlock()
    }
}

extension Trait where Self == SwiftDataSerialized {
    /// Serialize this suite against every other `.swiftDataSerialized` suite (ROH-65).
    static var swiftDataSerialized: SwiftDataSerialized { SwiftDataSerialized() }
}
