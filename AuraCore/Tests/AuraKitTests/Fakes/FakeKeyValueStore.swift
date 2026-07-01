import Foundation
@testable import AuraKit

/// In-memory KeyValueSyncing for tests. Records writes and lets a test push an
/// external change through `externalChanges`.
final class FakeKeyValueStore: KeyValueSyncing, @unchecked Sendable {
    private var storage: [String: Any] = [:]
    private let continuation: AsyncStream<KeyValueChange>.Continuation
    let externalChanges: AsyncStream<KeyValueChange>

    init() {
        var cont: AsyncStream<KeyValueChange>.Continuation!
        externalChanges = AsyncStream { cont = $0 }
        continuation = cont
    }

    func string(forKey key: String) -> String? { storage[key] as? String }
    func double(forKey key: String) -> Double? { storage[key] as? Double }
    func bool(forKey key: String) -> Bool? { storage[key] as? Bool }
    func hasValue(forKey key: String) -> Bool { storage[key] != nil }
    /// Per-key write count, so a test can assert the echo guard suppressed a write-back.
    private(set) var setCounts: [String: Int] = [:]
    func set(_ value: String?, forKey key: String) { storage[key] = value; setCounts[key, default: 0] += 1 }
    func set(_ value: Double, forKey key: String) { storage[key] = value; setCounts[key, default: 0] += 1 }
    func set(_ value: Bool, forKey key: String) { storage[key] = value; setCounts[key, default: 0] += 1 }
    @discardableResult func synchronize() -> Bool { true }

    /// Seed a value as if a peer had written it, then emit the change.
    func seed(_ value: Any, forKey key: String) { storage[key] = value }
    func simulateExternalChange(_ change: KeyValueChange) { continuation.yield(change) }
}
