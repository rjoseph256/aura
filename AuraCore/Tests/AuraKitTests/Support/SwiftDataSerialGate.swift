import Testing

/// Process-wide serialization gate for tests that build SwiftData `ModelContainer`s which
/// register `SavedPlaceRecord`.
///
/// That entity exists as two `@Model` classes sharing one CoreData entity name —
/// `RideSchemaV3.SavedPlaceRecord` (no `resurface`) and `RideSchemaV5.SavedPlaceRecord`
/// (adds it). CoreData caches entity descriptions **process-globally by entity name**, so if
/// two containers pinning different versions are alive at once (e.g. the V4→V5 migration suite
/// running concurrently with any V5 container suite), an object can bind to the wrong version
/// and setting `resurface` crashes the whole process with `setValue:forUndefinedKey:`.
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
/// two `SavedPlaceRecord`-container suites execute concurrently. Apply with `.swiftDataSerialized`.
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
