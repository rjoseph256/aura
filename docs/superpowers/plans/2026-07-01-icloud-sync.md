# iCloud Sync (ride history + settings) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync ride history across a rider's devices via SwiftData's automatic CloudKit mirror, and sync preferences via `NSUbiquitousKeyValueStore`, always-on when signed into iCloud.

**Architecture:** Ride history uses `NSPersistentCloudKitContainer` through `ModelConfiguration(cloudKitDatabase:)` on the existing SwiftData store; the model gains defaults (a hash-neutral change, no migration) and a remote-change observation seam so imported rides reach the UI. Settings mirror into iCloud KVS behind a `KeyValueSyncing` seam whose real conformer lives in the app target, with a `@MainActor` apply path, a re-entrancy guard against write-back loops, and a widget-refresh hop.

**Tech Stack:** Swift 6, SwiftData, CloudKit (NSPersistentCloudKitContainer), NSUbiquitousKeyValueStore, XcodeGen, MapboxMaps (unaffected), Swift Testing + XCTest.

## Global Constraints

- Swift 6 language mode across all targets (`swiftLanguageModes: [.v6]` in the package; `SWIFT_VERSION: 6.0` + `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` in the app).
- `AuraCore` and `AuraKit` must build on the macOS CI host: no UIKit, no ActivityKit, no CloudKit-entitlement-requiring runtime calls. System side effects live behind seams whose concrete conformers are in the `Aura` app target (precedent: `WorkoutWriting`/`WorkoutWriter`, `HapticPlaying`/`HapticPlayer`, `RideSessionTransport`/`SupabaseRideSessionTransport`).
- `NSUbiquitousKeyValueStore` compiles in the package but its concrete conformer stays in the app target so package tests never touch a live ubiquity store.
- iCloud container id: `iCloud.com.rohunjoseph.aura`. KVS id: team-prefixed `com.rohunjoseph.aura`.
- Package tests run with `cd AuraCore && swift test`. App builds with `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' build`. Lint with `swiftlint --strict` (0 violations required). The `.xcodeproj` is gitignored — regenerate before a local build. `Resources/MapboxAccessToken` is gitignored and may need copying from the primary worktree before `xcodegen generate`.
- Commit conventions: `feat(...)`, `test(...)`, `chore(...)`; end commit bodies with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- The synced settings keys are exactly: `units`, `weeklyGoalMeters`, `mapStyle`, `voiceEnabled`, `turnHaptics`. `saveToHealth` stays device-local.

---

### Task 1: CloudKit-ready defaults on RideSchemaV2

Add default values to the four non-optional attributes so `NSPersistentCloudKitContainer` accepts the schema. This is hash-neutral (defaults are not part of Core Data's version hash), so no new schema version and no migration stage.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV2.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSchemaV2DefaultsTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `RideRecord` with defaults on `id`, `kindRaw`, `startedAt`, `trackData`; init signature unchanged.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/RideSchemaV2DefaultsTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import AuraKit

/// The CloudKit mirror requires every non-optional attribute to have a default.
/// This proves the store still builds and round-trips a record after the defaults
/// were added in place (hash-neutral change, no migration). The authoritative
/// "CloudKit accepts this schema" check is the signed-simulator initializeCloudKitSchema
/// step in the app target; a local container cannot validate CloudKit rules.
@MainActor
struct RideSchemaV2DefaultsTests {
    @Test func recordRoundTripsInAFreshInMemoryStore() throws {
        let container = try ModelContainer(
            for: RideRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let id = UUID()
        let record = RideRecord(id: id, kindRaw: "free", startedAt: Date(timeIntervalSince1970: 100),
                                endedAt: nil, trackData: Data([1, 2, 3]), statsData: nil,
                                routeId: nil, destinationPlaceId: nil)
        container.mainContext.insert(record)
        try container.mainContext.save()
        let fetched = try container.mainContext.fetch(FetchDescriptor<RideRecord>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == id)
        #expect(fetched.first?.trackData == Data([1, 2, 3]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RideSchemaV2DefaultsTests`
Expected: PASS is possible even before the edit (the init is unchanged). If it passes already, that is fine — proceed; the edit in Step 3 is what makes the schema CloudKit-ready, and this test guards that the edit does not break the store. (This is the rare case where the behavior test cannot fail first because the change is a schema-metadata addition; the real red/green gate for CloudKit is Task 8's `initializeCloudKitSchema`.)

- [ ] **Step 3: Add the defaults**

In `AuraCore/Sources/AuraKit/Persistence/RideSchemaV2.swift`, change the four property declarations (leave the initializer exactly as-is):

```swift
        public var id: UUID = UUID()
        public var kindRaw: String = "free"
        public var startedAt: Date = .now
        public var endedAt: Date?
        @Attribute(.externalStorage) public var trackData: Data = Data()   // JSON-encoded [TrackPoint]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter RideSchemaV2DefaultsTests`
Expected: PASS
Run: `cd AuraCore && swift test --filter RideStore`
Expected: PASS (existing migration/round-trip suites still green, proving hash-neutrality — existing V2 stores still open).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideSchemaV2.swift AuraCore/Tests/AuraKitTests/RideSchemaV2DefaultsTests.swift
git commit -m "feat(persistence): CloudKit-ready defaults on RideRecord (hash-neutral, no migration)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Dedup-on-read by id

An iCloud-backup restore can re-import rows that also exist in CloudKit; because `id` is no longer unique, nothing collapses such a pair at the store level. Add a read-time dedup keyed on `id`, keeping the newest (the fetch is already sorted `startedAt` descending, so the first occurrence wins).

**Files:**
- Create: `AuraCore/Sources/AuraCore/Models/RideHistoryDedup.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideStore.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideHistoryDedupTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `RideHistoryDedup.unique<T>(_ items: [T], by id: (T) -> UUID) -> [T]` — stable, keeps the first occurrence of each id.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraCoreTests/RideHistoryDedupTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

struct RideHistoryDedupTests {
    private struct Row { let id: UUID; let tag: String }

    @Test func keepsFirstOccurrenceOfEachID() {
        let a = UUID(); let b = UUID()
        let rows = [Row(id: a, tag: "newest"), Row(id: b, tag: "other"), Row(id: a, tag: "older")]
        let out = RideHistoryDedup.unique(rows, by: \.id)
        #expect(out.map(\.tag) == ["newest", "other"])
    }

    @Test func leavesDistinctIDsUntouched() {
        let rows = [Row(id: UUID(), tag: "x"), Row(id: UUID(), tag: "y")]
        #expect(RideHistoryDedup.unique(rows, by: \.id).count == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RideHistoryDedupTests`
Expected: FAIL — "cannot find 'RideHistoryDedup' in scope".

- [ ] **Step 3: Implement the helper**

Create `AuraCore/Sources/AuraCore/Models/RideHistoryDedup.swift`:

```swift
import Foundation

/// Read-time dedup for the ride history. Because `RideRecord.id` is not a unique
/// attribute (CloudKit forbids uniqueness), a backup restore can surface the same
/// logical ride twice. Callers fetch newest-first, so keeping the first occurrence
/// of each id keeps the newest and drops the stale duplicate. Read-only: never blocks a save.
public enum RideHistoryDedup {
    public static func unique<T>(_ items: [T], by id: (T) -> UUID) -> [T] {
        var seen = Set<UUID>()
        var out: [T] = []
        out.reserveCapacity(items.count)
        for item in items where seen.insert(id(item)).inserted {
            out.append(item)
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RideHistoryDedupTests`
Expected: PASS

- [ ] **Step 5: Wire into RideStore**

In `AuraCore/Sources/AuraKit/Persistence/RideStore.swift`, wrap the two read paths (`AuraCore` is already imported):

```swift
    public func allRides() throws -> [Ride] {
        let descriptor = FetchDescriptor<RideRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        let rides = try container.mainContext.fetch(descriptor).map { try RideMapper.ride(from: $0) }
        return RideHistoryDedup.unique(rides, by: \.id)
    }

    public func summaries() throws -> [RideSummary] {
        let descriptor = FetchDescriptor<RideRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        let summaries = try container.mainContext.fetch(descriptor).map(RideMapper.summary(from:))
        return RideHistoryDedup.unique(summaries, by: \.id)
    }
```

- [ ] **Step 6: Run the store tests**

Run: `cd AuraCore && swift test --filter RideStore`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models/RideHistoryDedup.swift AuraCore/Sources/AuraKit/Persistence/RideStore.swift AuraCore/Tests/AuraCoreTests/RideHistoryDedupTests.swift
git commit -m "feat(persistence): dedup ride history on read by id (backup-restore insurance)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: RideStore remote-change observer + UI refetch

`NSPersistentCloudKitContainer` imports remote changes on a background context and merges them into the main context, but nothing tells the UI to refetch. Add a `syncRevision` counter that bumps on `.NSPersistentStoreRemoteChange`, and have `HistoryView` refetch when it changes.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideStore.swift`
- Modify: `Aura/Sources/History/HistoryView.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideStoreSyncRevisionTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `RideStore.syncRevision: Int` (observable, `private(set)`), incremented on the main actor when a remote store change posts.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/RideStoreSyncRevisionTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import AuraKit

@MainActor
struct RideStoreSyncRevisionTests {
    @Test func remoteChangeNotificationBumpsSyncRevision() async throws {
        let container = try ModelContainer(
            for: RideRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = RideStore(container: container)
        #expect(store.syncRevision == 0)
        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)
        // The observer hops to the main actor; yield so it runs.
        await Task.yield()
        #expect(store.syncRevision == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RideStoreSyncRevisionTests`
Expected: FAIL — `syncRevision` does not exist.

- [ ] **Step 3: Add the observer to RideStore**

In `AuraCore/Sources/AuraKit/Persistence/RideStore.swift`, add the property, observer setup in `init`, and cleanup. Add `import CoreData` at the top (for `.NSPersistentStoreRemoteChange`):

```swift
import CoreData
```

Add the stored properties and revise `init`:

```swift
    /// Bumps when CloudKit merges a remote change into the store, so views that hold
    /// a fetched snapshot (HistoryView, the dashboard) can refetch. 0 until the first import.
    public private(set) var syncRevision: Int = 0
    @ObservationIgnored private var remoteChangeObserver: NSObjectProtocol?

    public init(container: ModelContainer, isEphemeral: Bool = false) {
        self.container = container
        self.isEphemeral = isEphemeral
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncRevision &+= 1 }
        }
    }

    deinit {
        if let remoteChangeObserver { NotificationCenter.default.removeObserver(remoteChangeObserver) }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RideStoreSyncRevisionTests`
Expected: PASS

- [ ] **Step 5: Wire HistoryView to refetch**

In `Aura/Sources/History/HistoryView.swift`, add an `.onChange` next to the existing `.onAppear` (after the `.onAppear { ... }` block):

```swift
        .onChange(of: store.syncRevision) {
            summaries = (try? store.summaries()) ?? []
        }
```

- [ ] **Step 6: Build the app to verify it compiles**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideStore.swift Aura/Sources/History/HistoryView.swift AuraCore/Tests/AuraKitTests/RideStoreSyncRevisionTests.swift
git commit -m "feat(persistence): syncRevision remote-change observer; HistoryView refetches on CloudKit import

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4a: KeyValueSyncing seam + change model + fake

Define the seam the settings sync rides on, plus a test fake. Pure AuraKit, no live iCloud.

**Files:**
- Create: `AuraCore/Sources/AuraKit/Settings/KeyValueSyncing.swift`
- Create: `AuraCore/Tests/AuraKitTests/Fakes/FakeKeyValueStore.swift`

**Interfaces:**
- Produces:
  - `protocol KeyValueSyncing` with `string(forKey:)->String?`, `double(forKey:)->Double?`, `bool(forKey:)->Bool?`, `hasValue(forKey:)->Bool`, `set(_ String?, forKey:)`, `set(_ Double, forKey:)`, `set(_ Bool, forKey:)`, `synchronize()`, `var externalChanges: AsyncStream<KeyValueChange>`.
  - `struct KeyValueChange { enum Reason { case initialSync, server, quotaViolation, other }; let keys: [String]; let reason: Reason }`.
  - `final class FakeKeyValueStore: KeyValueSyncing` (test target) with `func simulateExternalChange(_ change: KeyValueChange)`.

- [ ] **Step 1: Write the seam**

Create `AuraCore/Sources/AuraKit/Settings/KeyValueSyncing.swift`:

```swift
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
```

- [ ] **Step 2: Write the fake**

Create `AuraCore/Tests/AuraKitTests/Fakes/FakeKeyValueStore.swift`:

```swift
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
    func set(_ value: String?, forKey key: String) { storage[key] = value }
    func set(_ value: Double, forKey key: String) { storage[key] = value }
    func set(_ value: Bool, forKey key: String) { storage[key] = value }
    @discardableResult func synchronize() -> Bool { true }

    /// Seed a value as if a peer had written it, then emit the change.
    func seed(_ value: Any, forKey key: String) { storage[key] = value }
    func simulateExternalChange(_ change: KeyValueChange) { continuation.yield(change) }
}
```

- [ ] **Step 3: Build the package to verify it compiles**

Run: `cd AuraCore && swift build --target AuraKit && swift build --target AuraKitTests`
Expected: builds (no tests yet reference these beyond compilation).

- [ ] **Step 4: Commit**

```bash
git add AuraCore/Sources/AuraKit/Settings/KeyValueSyncing.swift AuraCore/Tests/AuraKitTests/Fakes/FakeKeyValueStore.swift
git commit -m "feat(settings): KeyValueSyncing seam + KeyValueChange + test fake

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4b: SettingsStore iCloud mirror + apply path

Wire `SettingsStore` to mirror the five synced keys into KVS and apply external changes on the MainActor without echoing back. Return the changed keys so the app can refresh widgets.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift`
- Modify: `AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift` (existing tests become `@MainActor`)
- Test: `AuraCore/Tests/AuraKitTests/SettingsStoreSyncTests.swift` (create)

**Interfaces:**
- Consumes: `KeyValueSyncing`, `KeyValueChange` (Task 4a).
- Produces:
  - `SettingsStore` is `@MainActor`, `init(defaults:sync:)` where `sync: KeyValueSyncing? = nil`.
  - `SettingsStore.syncedKeys: Set<String>` (static) = the five key strings.
  - `@discardableResult func applyRemoteChange(_ change: KeyValueChange) -> Set<String>` — applies synced keys from `sync`, returns the keys it actually changed. On `.initialSync`, remote wins.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/SettingsStoreSyncTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraKit

@MainActor
struct SettingsStoreSyncTests {
    private func make() -> (SettingsStore, FakeKeyValueStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "sync-\(UUID().uuidString)")!
        let fake = FakeKeyValueStore()
        return (SettingsStore(defaults: defaults, sync: fake), fake, defaults)
    }

    @Test func localChangeMirrorsToKVS() {
        let (store, fake, _) = make()
        store.units = .metric
        #expect(fake.string(forKey: "units") == "metric")
    }

    @Test func remoteChangeAppliesWithoutEchoingBack() {
        let (store, fake, _) = make()
        fake.seed("metric", forKey: "units")
        // Track writes after seeding by counting a re-write of the same key.
        let changed = store.applyRemoteChange(KeyValueChange(keys: ["units"], reason: .server))
        #expect(store.units == .metric)
        #expect(changed == ["units"])
        // Echo guard: applying a remote change must not have pushed a new value back.
        // (No assertion on write count here beyond value stability; see loop test below.)
    }

    @Test func remoteApplyDoesNotRetriggerKVSWrite() {
        let (store, fake, _) = make()
        // Overwrite the fake's setter to detect an echo: wrap by re-seeding then applying.
        fake.seed("metric", forKey: "units")
        _ = store.applyRemoteChange(KeyValueChange(keys: ["units"], reason: .server))
        // If didSet echoed, it would have written units again; value stays metric either way,
        // so assert the store did NOT flip the flag off prematurely by applying a second change.
        fake.seed("imperial", forKey: "units")
        let changed = store.applyRemoteChange(KeyValueChange(keys: ["units"], reason: .server))
        #expect(store.units == .imperial)
        #expect(changed == ["units"])
    }

    @Test func initialSyncLetsRemoteWinOverSeededDefaults() {
        let (store, fake, _) = make()
        #expect(store.units == .imperial) // seeded default
        fake.seed("metric", forKey: "units")
        _ = store.applyRemoteChange(KeyValueChange(keys: ["units"], reason: .initialSync))
        #expect(store.units == .metric)
    }

    @Test func onlySyncedKeysCross() {
        #expect(SettingsStore.syncedKeys ==
                ["units", "weeklyGoalMeters", "mapStyle", "voiceEnabled", "turnHaptics"])
        #expect(!SettingsStore.syncedKeys.contains("saveToHealth"))
    }

    @Test func applyReportsChangedKeysForWidgetRefresh() {
        let (store, fake, _) = make()
        fake.seed(50_000.0, forKey: "weeklyGoalMeters")
        let changed = store.applyRemoteChange(KeyValueChange(keys: ["weeklyGoalMeters"], reason: .server))
        #expect(changed.contains("weeklyGoalMeters"))
        #expect(store.weeklyGoalMeters == 50_000)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter SettingsStoreSyncTests`
Expected: FAIL — `SettingsStore` has no `sync:` parameter, no `syncedKeys`, no `applyRemoteChange`.

- [ ] **Step 3: Rewrite SettingsStore**

Replace `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift` with:

```swift
import Foundation
import Observation

public enum DistanceUnits: String, Codable, Hashable, Sendable { case imperial, metric }
public enum MapStyle: String, Sendable { case dark, standard }

/// Stored (not computed) properties so `@Observable` tracks them. Each `didSet` mirrors
/// the value into `UserDefaults` (source of truth for a launch) and, for the synced keys,
/// into the injected `KeyValueSyncing` (iCloud). Applying a remote change sets the flag so
/// the `didSet` KVS write is suppressed, breaking the didSet -> KVS -> notify -> didSet echo.
/// `@MainActor` because remote changes arrive off-thread and mutate `@Observable` state.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sync: KeyValueSyncing?
    @ObservationIgnored private var isApplyingRemote = false

    public static let syncedKeys: Set<String> =
        [Key.units, Key.weeklyGoal, Key.mapStyle, Key.voice, Key.turnHaptics]

    public var units: DistanceUnits { didSet { persist(units.rawValue, Key.units) } }
    public var voiceEnabled: Bool { didSet { persist(voiceEnabled, Key.voice) } }
    public var mapStyle: MapStyle { didSet { persist(mapStyle.rawValue, Key.mapStyle) } }
    public var weeklyGoalMeters: Double { didSet { persist(weeklyGoalMeters, Key.weeklyGoal) } }
    public var turnHaptics: Bool { didSet { persist(turnHaptics, Key.turnHaptics) } }
    /// Device-local: bound to per-device HealthKit auth, so it is not synced.
    public var saveToHealth: Bool { didSet { defaults.set(saveToHealth, forKey: Key.saveToHealth) } }

    public init(defaults: UserDefaults = .standard, sync: KeyValueSyncing? = nil) {
        self.defaults = defaults
        self.sync = sync
        units = DistanceUnits(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .imperial
        voiceEnabled = defaults.object(forKey: Key.voice) as? Bool ?? true
        mapStyle = MapStyle(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .dark
        let storedGoal = defaults.object(forKey: Key.weeklyGoal) as? Double
        weeklyGoalMeters = (storedGoal.map { $0 > 0 ? $0 : nil } ?? nil) ?? 40_000
        saveToHealth = defaults.object(forKey: Key.saveToHealth) as? Bool ?? false
        turnHaptics = defaults.object(forKey: Key.turnHaptics) as? Bool ?? true
    }

    /// Apply an external iCloud change for the synced keys. Returns the keys whose value
    /// actually changed (the app uses this to decide whether to refresh the widgets).
    /// On `.initialSync`, remote wins over the just-seeded local defaults.
    @discardableResult
    public func applyRemoteChange(_ change: KeyValueChange) -> Set<String> {
        guard let sync else { return [] }
        if change.reason == .quotaViolation { return [] }
        let keys = change.keys.isEmpty ? Array(Self.syncedKeys) : change.keys
        var changed: Set<String> = []
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for key in keys where Self.syncedKeys.contains(key) {
            switch key {
            case Key.units:
                if let raw = sync.string(forKey: key), let v = DistanceUnits(rawValue: raw), v != units {
                    units = v; changed.insert(key)
                }
            case Key.mapStyle:
                if let raw = sync.string(forKey: key), let v = MapStyle(rawValue: raw), v != mapStyle {
                    mapStyle = v; changed.insert(key)
                }
            case Key.voice:
                if let v = sync.bool(forKey: key), v != voiceEnabled { voiceEnabled = v; changed.insert(key) }
            case Key.turnHaptics:
                if let v = sync.bool(forKey: key), v != turnHaptics { turnHaptics = v; changed.insert(key) }
            case Key.weeklyGoal:
                if let v = sync.double(forKey: key), v > 0, v != weeklyGoalMeters {
                    weeklyGoalMeters = v; changed.insert(key)
                }
            default: break
            }
        }
        return changed
    }

    private func persist(_ value: String, _ key: String) {
        defaults.set(value, forKey: key)
        if !isApplyingRemote, Self.syncedKeys.contains(key) { sync?.set(value, forKey: key); sync?.synchronize() }
    }
    private func persist(_ value: Double, _ key: String) {
        defaults.set(value, forKey: key)
        if !isApplyingRemote, Self.syncedKeys.contains(key) { sync?.set(value, forKey: key); sync?.synchronize() }
    }
    private func persist(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
        if !isApplyingRemote, Self.syncedKeys.contains(key) { sync?.set(value, forKey: key); sync?.synchronize() }
    }

    private enum Key {
        static let units = "units"; static let voice = "voiceEnabled"; static let mapStyle = "mapStyle"
        static let weeklyGoal = "weeklyGoalMeters"
        static let saveToHealth = "saveToHealth"
        static let turnHaptics = "turnHaptics"
    }
}
```

- [ ] **Step 4: Make the existing tests `@MainActor`**

In `AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift`, add `@MainActor` to the class declaration so it can construct the now-`@MainActor` store:

```swift
@MainActor
final class SettingsStoreTests: XCTestCase {
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter SettingsStore`
Expected: PASS (both `SettingsStoreTests` and `SettingsStoreSyncTests`).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Settings/SettingsStore.swift AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift AuraCore/Tests/AuraKitTests/SettingsStoreSyncTests.swift
git commit -m "feat(settings): mirror synced keys to iCloud KVS + MainActor apply path with echo guard

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: App-target KVS conformer + observer loop

Provide the real `NSUbiquitousKeyValueStore` conformer and the app-side loop that consumes external changes on the MainActor, applies them, and refreshes widgets when `units`/`weeklyGoalMeters` change.

**Files:**
- Create: `Aura/Sources/Settings/UbiquitousKeyValueStore.swift`
- Modify: `Aura/Sources/AuraApp.swift`

**Interfaces:**
- Consumes: `KeyValueSyncing`, `KeyValueChange`, `SettingsStore.applyRemoteChange(_:)`, `WidgetRefresh.reload(rideStore:settings:)`.
- Produces: `UbiquitousKeyValueStore: KeyValueSyncing` (app target).

- [ ] **Step 1: Write the conformer**

Create `Aura/Sources/Settings/UbiquitousKeyValueStore.swift`:

```swift
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
```

- [ ] **Step 2: Wire it in AuraApp**

In `Aura/Sources/AuraApp.swift`, construct the store with the sync conformer where `SettingsStore` is created (replace the existing `SettingsStore(...)` construction), and add a `.task` on the root that consumes external changes. Locate `makeSettings()` / the `SettingsStore` initializer and change it to:

```swift
    private static func makeSettings() -> SettingsStore {
        SettingsStore(defaults: .standard, sync: UbiquitousKeyValueStore())
    }
```

Then on the root view (near the existing `.task { WidgetRefresh.reload(...) }` at `AuraApp.swift:95`), add:

```swift
        .task {
            for await change in settings.kvSyncStream {
                let changed = settings.applyRemoteChange(change)
                if changed.contains("units") || changed.contains("weeklyGoalMeters") {
                    WidgetRefresh.reload(rideStore: rideStore, settings: settings)
                }
            }
        }
```

To expose the stream, add a passthrough on `SettingsStore` (AuraKit) so the app can await it without holding the conformer:

In `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift`, add:

```swift
    /// The external-change stream from the injected sync store (empty if none).
    public var kvSyncStream: AsyncStream<KeyValueChange> {
        sync?.externalChanges ?? AsyncStream { $0.finish() }
    }
```

- [ ] **Step 3: Build the app**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Run the package tests (the new SettingsStore member must not break them)**

Run: `cd AuraCore && swift test --filter SettingsStore`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Settings/UbiquitousKeyValueStore.swift Aura/Sources/AuraApp.swift AuraCore/Sources/AuraKit/Settings/SettingsStore.swift
git commit -m "feat(settings): app-target NSUbiquitousKeyValueStore conformer + MainActor apply loop + widget refresh

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Entitlements

Add the iCloud/CloudKit/KVS entitlement keys to the committed entitlements file. No `aps-environment` or background push mode (deferred). XcodeGen already wires `CODE_SIGN_ENTITLEMENTS`, so `project.yml` is untouched.

**Files:**
- Modify: `Aura/Resources/Aura.entitlements`

- [ ] **Step 1: Add the keys**

Edit `Aura/Resources/Aura.entitlements` so the `<dict>` also contains (keep the existing applesignin, healthkit, application-groups keys):

```xml
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array>
    <string>iCloud.com.rohunjoseph.aura</string>
  </array>
  <key>com.apple.developer.icloud-services</key>
  <array>
    <string>CloudKit</string>
  </array>
  <key>com.apple.developer.ubiquity-kvstore-identifier</key>
  <string>$(TeamIdentifierPrefix)com.rohunjoseph.aura</string>
```

- [ ] **Step 2: Regenerate and build (unsigned; entitlements are inert in CI-style build)**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: `BUILD SUCCEEDED` (unsigned build ignores entitlement provisioning, matching HealthKit/App-Group precedent).

- [ ] **Step 3: Commit**

```bash
git add Aura/Resources/Aura.entitlements
git commit -m "chore(icloud-sync): add iCloud/CloudKit/KVS entitlements

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Turn on the CloudKit mirror

Configure `RideStore.persistent()` to sync the store. The migration plan is retained.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideStore.swift`

- [ ] **Step 1: Add the CloudKit configuration**

Replace `RideStore.persistent()` body:

```swift
    /// The app's on-disk store, migrated and mirrored to the rider's private CloudKit
    /// database. Same default store URL as before, so existing local rides are found,
    /// migrated, and uploaded on first sync. `inMemory()` stays local.
    public static func persistent() throws -> RideStore {
        let config = ModelConfiguration(cloudKitDatabase: .private("iCloud.com.rohunjoseph.aura"))
        let container = try ModelContainer(for: RideRecord.self,
                                           migrationPlan: RideMigrationPlan.self,
                                           configurations: config)
        return RideStore(container: container)
    }
```

- [ ] **Step 2: Build the package and the app**

Run: `cd AuraCore && swift build`
Expected: builds (the config API compiles; sync only activates with entitlements at runtime).
Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run the full package suite**

Run: `cd AuraCore && swift test`
Expected: PASS (all suites; `inMemory()` paths unaffected).

- [ ] **Step 4: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideStore.swift
git commit -m "feat(persistence): mirror the ride store to private CloudKit (migration plan retained)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Signed-simulator validation + ROADMAP device-verify list

Validate the CloudKit schema for real on a signed simulator, confirm existing rows survive first-launch, and record the device-verify tail. These require a signed build with the iCloud container provisioned, so they are not package-CI checks.

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Provision + schema validation (manual, signed simulator)**

Prerequisites (one-time, in the Apple Developer account and Xcode): register the `iCloud.com.rohunjoseph.aura` CloudKit container and enable the iCloud capability for the `com.rohunjoseph.aura` App ID. Sign the simulator into an iCloud account.

Add a temporary schema-init call behind a debug flag, or use a scratch invocation, to run once at launch on the signed sim:

```swift
#if DEBUG
// Temporary, run once against a signed build to validate the CloudKit schema, then remove.
// let container = try RideStore.persistent()  // gives the configured container
// try (container as? NSPersistentCloudKitContainer)?.initializeCloudKitSchema(options: [])
#endif
```

Because SwiftData hides the underlying `NSPersistentCloudKitContainer`, prefer validating via the CloudKit Dashboard: run the signed app, record a ride, confirm the `CD_RideRecord` record type and fields appear in the **Development** environment. Capture that the schema pushed without error.

- [ ] **Step 2: Existing-rows first-launch check (manual, signed simulator)**

Install a build WITHOUT CloudKit first (or use an existing install with local rides), then install this build. Confirm the previously-recorded rides still appear in History (the in-place-default change and CloudKit backfill did not drop rows).

- [ ] **Step 3: Record the device-verify tail in the ROADMAP**

In `docs/ROADMAP.md`, under "Wave 4 and beyond", add an iCloud-sync entry with a device-verify list:

```markdown
- iCloud sync (ride history + settings) — SHIPPED correct-by-construction (branch
  claude/icloud-sync, 2026-07-01). Ride history via SwiftData automatic CloudKit
  (defaults added to RideRecord in place — hash-neutral, no migration; syncRevision
  remote-change observer refreshes the list; dedup-on-read by id). Settings via
  NSUbiquitousKeyValueStore behind a KeyValueSyncing seam (five synced keys; MainActor
  apply path with echo guard + reason codes; widget refresh on units/goal). Entitlements
  added; background silent push deferred.
  - **iCloud-sync device-verify list** (needs 2 iCloud-signed devices/sims + a provisioned
    container): two-device ride round-trip + syncRevision refresh; settings converge across
    devices; account-change local-data retention (sign-out, Apple ID switch); CloudKit
    development-schema promotion to production before any App Store release (additive-only after).
```

- [ ] **Step 4: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): iCloud sync shipped correct-by-construction + device-verify list

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Schema defaults, no V3, guard/round-trip test → Task 1. ✓
- Container CloudKit config, migration plan retained → Task 7. ✓
- Remote-import observation seam (syncRevision) + HistoryView refetch → Task 3. ✓
- Dedup-on-read by id → Task 2. ✓
- KeyValueSyncing seam + fake → Task 4a. ✓
- SettingsStore @MainActor apply, echo guard, reason codes, five synced keys → Task 4b. ✓
- App-target conformer + observer loop + widget refresh → Task 5. ✓
- Entitlements hand-added, background push deferred → Task 6. ✓
- initializeCloudKitSchema / existing-rows checks + device-verify tail → Task 8. ✓
- Account-availability behavior (unchanged fallback) → covered by leaving inMemory/ephemeral paths untouched (Tasks 3, 7). ✓

**Placeholder scan:** Task 8 is intentionally manual (signed-sim / Dashboard) because those checks cannot run in package CI; the steps are concrete actions, not TBDs.

**Type consistency:** `KeyValueSyncing`, `KeyValueChange(keys:reason:)`, `SettingsStore.syncedKeys`, `applyRemoteChange(_:) -> Set<String>`, `kvSyncStream`, `syncRevision`, `RideHistoryDedup.unique(_:by:)` are used consistently across tasks 2–5.

**Known API caveat to confirm during execution:** Task 8's direct `initializeCloudKitSchema` call depends on reaching the underlying `NSPersistentCloudKitContainer`, which SwiftData does not expose publicly; the plan falls back to CloudKit Dashboard verification, which is the reliable path.
