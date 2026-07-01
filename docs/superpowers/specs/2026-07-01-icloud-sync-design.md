# iCloud sync — ride history + settings

Status: approved design, 2026-07-01. Wave 4 "and beyond" item.

Sync a rider's history and preferences across their devices. Two mechanisms, each
the native tool for its data:

- **Ride history** rides on SwiftData's automatic CloudKit mirror
  (`NSPersistentCloudKitContainer`, reached through `ModelConfiguration(cloudKitDatabase:)`).
- **Settings** ride on `NSUbiquitousKeyValueStore` (iCloud key-value store).

Both are always-on when the device is signed into iCloud. There is no in-app toggle;
a rider who wants to stop syncing turns the app off in system iCloud settings, the
same as Photos or Journal.

## Why this is unblocked now

Wave 1's persistence rebuild removed the CloudKit blockers already: `RideRecord`
dropped `@Attribute(.unique)` on `id`, moved the GPS track to
`@Attribute(.externalStorage)`, and carries no relationships. What remains is a small
schema adjustment (defaults), the container configuration, the entitlements, and the
dev-to-production schema rollout.

## Ride history sync

### Schema: RideSchemaV3

CloudKit needs every non-optional attribute to carry a default value, because a record
synced down can arrive with a field missing. Four attributes on the current
`RideSchemaV2.RideRecord` have no default: `id`, `kindRaw`, `startedAt`, `trackData`.

`RideSchemaV3` gives each one a default and keeps it non-optional (the SwiftData
guidance is to default required scalars, not blanket-optionalize them):

- `id` = `UUID()`
- `kindRaw` = `"free"`
- `startedAt` = `.now`
- `trackData` = `Data()`

Everything else is unchanged and already CloudKit-compatible. `RideSchemaV1` stays
frozen; `RideSchemaV2` stays as the prior version in the plan.

`RideMigrationPlan` gains a **lightweight** V2→V3 stage. Adding defaults does not
rewrite existing rows, so no custom `didMigrate` is needed. The `RideRecord` typealias
repoints to `RideSchemaV3.RideRecord`.

### Container configuration

`RideStore.persistent()` builds the container with an explicit configuration that turns
on the CloudKit mirror and keeps the default on-disk store URL, so existing local rides
are found, migrated to V3, and uploaded on first sync:

```swift
let config = ModelConfiguration(cloudKitDatabase: .private("iCloud.com.rohunjoseph.aura"))
let container = try ModelContainer(for: RideRecord.self,
                                   migrationPlan: RideMigrationPlan.self,
                                   configurations: config)
```

`RideStore.inMemory()` stays local (no CloudKit) for tests and previews. The store's
save/fetch/delete methods do not change: CloudKit mirrors the store underneath them.

### Conflicts

Rides are append-only and immutable once recorded, and a ride recorded on one device is
never edited on another. The only cross-device operation is deletion, which propagates
cleanly. CloudKit's default last-writer-wins is correct here, so there is no custom
conflict resolution.

### Account availability

With no iCloud account (or iCloud disabled for the app), the store behaves exactly as it
does today: it reads and writes locally, and the existing in-memory ephemeral fallback
for a failed on-disk container is untouched. Sync begins on its own when an account
becomes available; the app does not gate ride recording on iCloud.

## Settings sync

### Mechanism

A small seam, `KeyValueSyncing`, abstracts `NSUbiquitousKeyValueStore`: get/set for the
value types in play, `synchronize()`, and a stream of external-change notifications
(key list plus change reason). `SettingsStore` takes one, alongside the `UserDefaults` it
already takes.

- A local settings change writes through to both `UserDefaults` (unchanged, the source
  of truth for a launch) and the key-value store.
- An external change (another device wrote) updates `UserDefaults` and then the matching
  `@Observable` properties, so any view reading the setting re-renders.

The app injects the real `NSUbiquitousKeyValueStore` conformer. Tests inject a fake, so
the mirror-and-merge logic is verified with no live iCloud.

### Which keys sync

Synced (user-global preferences):

- `units`
- `weeklyGoalMeters`
- `mapStyle`
- `voiceEnabled`

Device-local (left out on purpose):

- `saveToHealth` — bound to per-device HealthKit authorization; syncing "on" to a device
  that never granted HealthKit would misrepresent state.
- `turnHaptics` — a per-device feel preference.

## Capabilities and build

Added to `Aura.entitlements` through XcodeGen (`project.yml`):

- `com.apple.developer.icloud-container-identifiers`: `[iCloud.com.rohunjoseph.aura]`
- `com.apple.developer.icloud-services`: `[CloudKit]`
- `com.apple.developer.ubiquity-kvstore-identifier`: the team-prefixed KVS id
- `aps-environment` (CloudKit's silent-push channel)

Added to `Info.plist`: `remote-notification` in `UIBackgroundModes`, so sync pushes land
while the app is backgrounded.

These are consumed at sign time. CI builds the app unsigned, so the CI build stays green
without the iCloud container being provisioned, the same way the HealthKit entitlement and
the App Group already behave. The `AuraWidgets` extension is untouched: it reads the
denormalized `WidgetSnapshot` from the App Group, not the SwiftData store, so CloudKit on
the store does not reach it.

## Testing

Device-independent, in the package and on one simulator:

- **V2→V3 migration round-trip** (AuraKit): write V2-shaped rows, reopen through the plan,
  assert row count, external track bytes, and the summary columns all survive. Mirrors the
  existing V1→V2 test.
- **Settings mirror/merge** (AuraKit, injected fake KVS): a local change writes to both
  stores; an external change updates the store and fires an observation; only the four
  synced keys cross, the two device-local keys do not.
- **One-simulator init smoke**: the CloudKit-configured container initializes without
  crashing on a signed simulator and pushes the development schema.

## Done-bar and the device-verify tail

The build is device-independent and ships correct-by-construction. Two things genuinely
need real accounts or hardware and are called out, not claimed:

- **Two-device round-trip.** Proving a ride recorded on device A appears on device B needs
  two iCloud-signed devices or simulators. This is a device-verify item, like the
  group-ride live path and HealthKit's lock screen.
- **Production schema promotion.** The CloudKit development schema must be verified in the
  CloudKit Dashboard and promoted to production before any App Store release, and after
  promotion the schema changes only additively. This is an account-gated release step.

Both go on the ROADMAP as the sync device-verify list, alongside the group-ride one.

## Rollout order

1. `RideSchemaV3` + lightweight migration stage + round-trip test.
2. `KeyValueSyncing` seam + `SettingsStore` wiring + fake-backed tests.
3. Entitlements + Info.plist + XcodeGen, and the real `NSUbiquitousKeyValueStore` conformer.
4. `RideStore.persistent()` CloudKit configuration.
5. One-simulator init smoke; record the device-verify tail on the ROADMAP.
