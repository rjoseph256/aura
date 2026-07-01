import Foundation

/// One external key-value change from iCloud (a peer wrote, or the first sync landed).
public struct KeyValueChange: Sendable {
    public enum Reason: Sendable { case initialSync, server, quotaViolation, other }
    public let keys: [String]
    public let reason: Reason
    public init(keys: [String], reason: Reason) {
        self.keys = keys
        self.reason = reason
    }
}

/// Abstraction over `NSUbiquitousKeyValueStore`. The real conformer lives in the app
/// target so package tests never touch a live ubiquity store; tests inject a fake.
public protocol KeyValueSyncing: Sendable {
    func string(forKey key: String) -> String?
    func double(forKey key: String) -> Double?
    func bool(forKey key: String) -> Bool?
    func hasValue(forKey key: String) -> Bool
    func set(_ value: String?, forKey key: String)
    func set(_ value: Double, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    @discardableResult func synchronize() -> Bool
    /// Emits when another device writes. Consume on the MainActor before touching UI state.
    var externalChanges: AsyncStream<KeyValueChange> { get }
}
