# iCloud sync — ride history + settings

Status: approved design, revised 2026-07-01 after a three-reviewer adversarial pass.
Wave 4 "and beyond" item.

Sync a rider's history and preferences across their devices. Two mechanisms, each the
native tool for its data:

- **Ride history** rides on SwiftData's automatic CloudKit mirror
  (`NSPersistentCloudKitContainer`, reached through `ModelConfiguration(cloudKitDatabase:)`).
- **Settings** ride on `NSUbiquitousKeyValueStore` (iCloud key-value store).

Both are always-on when the device is signed into iCloud. There is no in-app toggle; a
rider who wants to stop syncing turns the app off in system iCloud settings, the same as
Photos or Journal.

## Why this is unblocked now

Wave 1's persistence rebuild removed the CloudKit blockers already: `RideRecord` dropped
`@Attribute(.unique)` on `id`, moved the GPS track to `@Attribute(.externalStorage)`, and
carries no relationships. What remains is a small schema adjustment (defaults), the
container configuration, an observation seam so synced-in data reaches the UI, the
entitlements, and the dev-to-production schema rollout.

## Ride history sync

### Schema: add defaults in place, no new version

CloudKit needs every non-optional attribute to carry a default value, because a record
synced down can arrive with a field missing. Four attributes on the current
`RideSchemaV2.RideRecord` have no default: `id`, `kindRaw`, `startedAt`, `trackData`.

These gain defaults, kept non-optional (the SwiftData guidance is to default required
scalars, not blanket-optionalize them):

- `id` = `UUID()`
- `kindRaw` = `"free"`
- `startedAt` = `.now`
- `trackData` = `Data()`

**This is not a schema version bump and needs no migration stage.** A default value is not
part of Core Data's entity version hash, so `id: UUID` and `id: UUID = UUID()` produce the
same store hash. Adding the defaults to `RideSchemaV2` in place leaves existing on-device
V2 stores opening with no migration, and the rows keep their real values. A `RideSchemaV3`
with a "lightweight V2→V3 stage" would migrate nothing (identical hashes) and only add dead
ceremony, so it is deliberately not introduced. `RideMigrationPlan` stays at V1→V2; the
custom V1→V2 backfill stage is untouched. `RideSchemaV1` stays frozen.

Two device-independent guard tests protect this against a future regression:

- Enumerate `RideRecord`'s stored properties and assert every non-optional attribute has a
  default or is optional (CloudKit's hard requirement). A future added column without a
  default then fails CI, not the CloudKit Dashboard.
- Assert the model declares no `@Attribute(.unique)`/`#Unique` and no relationships, since
  re-adding either silently breaks the mirror.

### Container configuration

`RideStore.persistent()` builds the container with an explicit configuration that turns on
the CloudKit mirror and keeps the default on-disk store URL, so existing local rides are
found and uploaded on first sync. The migration plan is retained alongside the config:

```swift
let config = ModelConfiguration(cloudKitDatabase: .private("iCloud.com.rohunjoseph.aura"))
let container = try ModelContainer(for: RideRecord.self,
                                   migrationPlan: RideMigrationPlan.self,
                                   configurations: config)
```

`RideStore.inMemory()` stays local (no CloudKit, no plan) for tests and previews. Because
the migration and CloudKit paths only run in `persistent()`, preview and unit behavior is
not evidence the synced store works — the dedicated tests below cover it.

### Observation seam: synced-in rides must reach the UI

`RideStore` is `@MainActor @Observable` and fetches from `container.mainContext` on each
call; `HistoryView` reads `store.summaries()` into local `@State` (it does not use
`@Query`). `NSPersistentCloudKitContainer` imports remote changes on a private background
context and merges them into the main context, but nothing today tells the UI to refetch,
so a ride synced from another device would stay invisible until a manual refresh.

`RideStore` gains a remote-change observer: it subscribes to `.NSPersistentStoreRemoteChange`
for its store and bumps an observable `syncRevision` counter on the main actor. `HistoryView`
and the dashboard refetch when `syncRevision` changes. This keeps the existing summary read
path (which never faults the track blob) rather than switching to `@Query`.

### Duplicate identity safeguard

Rides are recorded once, on one device, with an `id` generated at record time; that `id`
never crosses to another device except through CloudKit itself, so normal use produces no
duplicates. The one edge is an iCloud-backup restore re-importing rows that also exist in
CloudKit. Because `id` is no longer unique (the constraint CloudKit forbids), nothing at the
store level collapses such a pair. As cheap insurance, the read paths (`summaries()`,
`allRides()`) dedupe by `id`, keeping the newest `startedAt`. This is a read-time filter, not
a write constraint, so it never blocks a save.

### Conflicts

Rides are append-only and immutable once recorded, and a ride recorded on one device is
never edited on another. The only cross-device mutation is deletion, which propagates
cleanly. CloudKit's default last-writer-wins is correct here, so there is no custom conflict
resolution.

### Account availability and account changes

- **No account, or iCloud disabled for the app:** the store reads and writes locally exactly
  as today, and the existing in-memory ephemeral fallback for a failed on-disk container is
  untouched. Sync begins on its own when an account becomes available.
- **Sign-out or Apple ID switch:** SwiftData keeps the local store; sync pauses, and local
  rows are not deleted by the sign-out itself. A different Apple ID gets its own sync and does
  not receive the prior account's rows. The exact local-retention behavior across an account
  switch is a device-verify item (below), not something this spec claims by construction.
- **Sign-out mid-ride:** recording does not gate on iCloud. A `save()` failure already routes
  through the `isEphemeral` fallback, so a container hiccup at ride end cannot lose the ride
  to an unhandled throw.

## Settings sync

### Mechanism and layering

A small seam, `KeyValueSyncing`, abstracts `NSUbiquitousKeyValueStore`: typed get/set for the
concrete keys, `synchronize()`, and an `AsyncStream` of external-change events carrying the
changed keys and the change reason. The real conformer wrapping `NSUbiquitousKeyValueStore`
lives in the **app target** (like `WorkoutWriter`, `HapticPlayer`, and the Supabase transport),
so the package's tests never touch a live ubiquity store. Tests inject a fake, so the
mirror-and-merge logic runs with no iCloud.

### Threading and the write-back loop

`SettingsStore`'s external-apply path is `@MainActor`. The app target owns the
`NSUbiquitousKeyValueStore` observer, consumes the seam's `AsyncStream` in a `@MainActor` task,
and calls the apply method on the main actor, so `@Observable` state is never mutated off-thread
(the app builds under Swift 6 default-MainActor isolation).

Applying a remote change must not echo back out. `SettingsStore` sets a re-entrancy flag while
it applies remote values, and the KVS write in each `didSet` is skipped while that flag is set.
Without this, a remote value assigned to a property fires its `didSet`, writes back to KVS, and
notifies again.

### Change reasons

The observer branches on `NSUbiquitousKeyValueStoreChangeReasonKey`:

- `InitialSyncChange` (first sync on this device): remote values win over the just-seeded
  local defaults for the synced keys.
- `ServerChange` (a peer wrote): apply the changed keys.
- `QuotaViolationChange`: log; the four small scalar keys cannot realistically exceed the
  1 MB / 1024-key limit, so there is no shedding logic.

Per-key resolution is last-writer-wins (KVS gives no timestamp to merge on), which is fine for
scalar preferences: two devices setting units differently converge on the most recent write.

### Which keys sync

Synced (user-global preferences): `units`, `weeklyGoalMeters`, `mapStyle`, `voiceEnabled`,
`turnHaptics`. Each marshals through its stored representation; the two enums round-trip via
their `String` rawValue (`DistanceUnits` is `Codable`; `MapStyle` is a `String` enum and is
stored by rawValue, so no `Codable` conformance is required).

Device-local (left out on purpose): `saveToHealth` only. It is bound to per-device HealthKit
authorization, so syncing "on" to a device that never granted HealthKit would misrepresent
state.

### Settings sync must refresh the widgets

`units` and `weeklyGoalMeters` are denormalized into the App Group `WidgetSnapshot` by
`WidgetRefresh.reload`, which today runs only from `SettingsView`, the ride HUDs, and
scene-phase changes. When an external KVS change updates either key, the app-target observer
calls `WidgetRefresh.reload` after applying it, so the other device's home and lock-screen
widgets do not show a stale goal or units. The pure `SettingsStore` does not call
`WidgetRefresh` (that is app-target); the app observer owns the hop.

## Capabilities and build

Added by hand to the committed `Resources/Aura.entitlements` (XcodeGen wires
`CODE_SIGN_ENTITLEMENTS` to that file already; it does not synthesize entitlement keys, so
`project.yml` needs no change):

- `com.apple.developer.icloud-container-identifiers`: `[iCloud.com.rohunjoseph.aura]`
- `com.apple.developer.icloud-services`: `[CloudKit]`
- `com.apple.developer.ubiquity-kvstore-identifier`: the team-prefixed KVS id

**Background silent push is deferred.** For v1, sync lands on app launch and foreground, which
covers the real use (open the app on the second device, the rides are there). That avoids
`aps-environment` (profile-managed, and pinning it in the plist can conflict on signed builds)
and the `remote-notification` background mode. Background push is a later enhancement, not a v1
dependency.

The entitlements are consumed at sign time. CI builds the app with `CODE_SIGNING_ALLOWED=NO`,
so the CI build stays green without the iCloud container being provisioned, the same way the
HealthKit entitlement and the App Group already behave. The iCloud container id and the KVS id
must be provisioned in the Apple Developer account before any signed run (device-verify tail).

The `AuraWidgets` extension is untouched: it reads the denormalized `WidgetSnapshot` from the
App Group, not the SwiftData store, and the two live in different containers (Application
Support vs the App Group), so CloudKit on the store cannot reach or corrupt the widget snapshot.
The only settings-to-widget coupling is the refresh hop above.

## Testing

Device-independent, in the package and on one simulator:

- **Schema invariant guards** (AuraKit): every non-optional `RideRecord` attribute has a
  default; no `.unique`/`#Unique` and no relationships. These catch a CloudKit-incompatible
  schema change in CI.
- **Store opens with defaults** (AuraKit): a store written before the defaults were added
  reopens and its rows are readable, proving the in-place default add is hash-neutral.
- **Dedup-on-read** (AuraKit): two rows with the same `id` collapse to one newest in
  `summaries()`/`allRides()`; distinct ids are untouched.
- **Settings mirror/merge** (AuraKit, injected fake KVS): a local change writes to both stores;
  a remote change applies without echoing back (re-entrancy guard); `InitialSyncChange` lets
  remote win over seeded defaults; only the five synced keys cross and `saveToHealth` does not;
  the units/goal change signals a widget refresh (observed through a spy).
- **CloudKit schema validation** (signed simulator): construct the CloudKit-configured
  container and call `initializeCloudKitSchema(options:)`; assert it returns without throwing.
  This is the only automated check that validates the schema against CloudKit rather than a
  local container.
- **Existing-rows first-launch** (signed simulator): a store pre-populated with local rides
  reopened with the CloudKit config still reads every row (history backfill did not drop data).

## Done-bar and the device-verify tail

The build is device-independent, and the schema is now validated by the CI invariant guards
plus the `initializeCloudKitSchema` simulator check, so "the schema CloudKit will accept" is no
longer an unverified assertion. Three things still need real accounts or hardware and are called
out, not claimed:

- **Two-device round-trip.** A ride recorded on device A appearing on device B, and the
  `syncRevision` observer refreshing the list, needs two iCloud-signed devices or simulators.
- **Account-change local retention.** Confirming sign-out and Apple ID switch behave as
  described (sync pauses, local rows retained) needs a real account.
- **Production schema promotion.** The CloudKit development schema is verified in the CloudKit
  Dashboard and promoted to production before any App Store release; after promotion the schema
  changes only additively.

These go on the ROADMAP as the sync device-verify list, alongside the group-ride one.

## Rollout order

1. Add the four defaults to `RideSchemaV2.RideRecord`; add the schema invariant guard tests and
   the store-opens-with-defaults test. (No new schema version, no migration-plan change.)
2. Dedup-on-read by `id` in `summaries()`/`allRides()` + test.
3. `RideStore` remote-change observer + `syncRevision`; wire `HistoryView`/dashboard refetch.
4. `KeyValueSyncing` seam + `SettingsStore` `@MainActor` apply path with re-entrancy guard and
   reason-code handling; fake-backed tests including the widget-refresh spy.
5. App-target real `NSUbiquitousKeyValueStore` conformer + the observer that hops to MainActor
   and calls `WidgetRefresh.reload` on units/goal changes.
6. Entitlements added to `Resources/Aura.entitlements`.
7. `RideStore.persistent()` CloudKit configuration (migration plan retained).
8. Signed-simulator checks: `initializeCloudKitSchema` and existing-rows first-launch. Record
   the device-verify tail on the ROADMAP.
