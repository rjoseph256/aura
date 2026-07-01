import Foundation
import AuraKit

/// Real `NSUbiquitousKeyValueStore`-backed `KeyValueSyncing`. Lives in the app target so
/// the package never touches a live ubiquity store. Translates the store's
/// didChangeExternally notification (arbitrary thread) into `KeyValueChange` values.
final class UbiquitousKeyValueStore: KeyValueSyncing, @unchecked Sendable {
    private let store = NSUbiquitousKeyValueStore.default
    let externalChanges: AsyncStream<KeyValueChange>
    private let continuation: AsyncStream<KeyValueChange>.Continuation
    private var observer: NSObjectProtocol?

    init() {
        var cont: AsyncStream<KeyValueChange>.Continuation!
        externalChanges = AsyncStream { cont = $0 }
        continuation = cont
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: nil
        ) { [continuation] note in
            let info = note.userInfo
            let keys = info?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            let reasonCode = info?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let reason: KeyValueChange.Reason
            switch reasonCode {
            case NSUbiquitousKeyValueStoreInitialSyncChange: reason = .initialSync
            case NSUbiquitousKeyValueStoreServerChange: reason = .server
            case NSUbiquitousKeyValueStoreQuotaViolationChange: reason = .quotaViolation
            default: reason = .other
            }
            continuation.yield(KeyValueChange(keys: keys, reason: reason))
        }
        store.synchronize()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func string(forKey key: String) -> String? { store.string(forKey: key) }
    func double(forKey key: String) -> Double? {
        store.object(forKey: key) == nil ? nil : store.double(forKey: key)
    }
    func bool(forKey key: String) -> Bool? {
        store.object(forKey: key) == nil ? nil : store.bool(forKey: key)
    }
    func hasValue(forKey key: String) -> Bool { store.object(forKey: key) != nil }
    func set(_ value: String?, forKey key: String) { store.set(value, forKey: key) }
    func set(_ value: Double, forKey key: String) { store.set(value, forKey: key) }
    func set(_ value: Bool, forKey key: String) { store.set(value, forKey: key) }
    @discardableResult func synchronize() -> Bool { store.synchronize() }
}
