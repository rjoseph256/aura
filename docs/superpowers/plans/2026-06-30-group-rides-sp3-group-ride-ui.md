# Group Rides SP3 — Group-Ride UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the group-ride UI — create/join-by-code, a rolling-join lobby, a live Mapbox map with named peer dots, a roster bottom sheet, and end/leave + toasts — over the shipped SP1 backend and SP2 transport.

**Architecture:** Pure logic (bearing, distance, name validation, roster view-data, deep-link parsing) lands in AuraCore, fully unit-tested. One `@Observable` owner, `GroupRideSession`, lives in AuraKit: it wraps the shipped `RideSession`, drives a **named `tick(now:)` clock seam** (production timer in the app target; tests pump time), holds a `nameMap` fed by a new `ride_roster` RPC, snapshots `peers`/`isLive` into observable state, and emits membership toasts. SwiftUI views in the app target read only that owner. `supabase-swift` stays in the app target.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, MapboxMaps (SwiftUI DSL + `MapViewAnnotation`), Supabase (Postgres RPC + RLS, pgTAP), Swift Testing.

## Global Constraints

- **supabase-swift only in the app target** (`Aura/Sources/Sync`). AuraCore is pure; AuraKit holds seams + the owner. The SwiftPM package must build on a macOS CI host — no iOS-only API in AuraCore/AuraKit without `#if os(iOS)`.
- **`RideSession` stays push-driven** — no `Date()`/`Task.sleep` inside it. `GroupRideSession.tick(now:)` is the SOLE time entry in the tested path; the real repeating timer is created only by production wiring (may use `Date()`/`Task.sleep`, mirroring `RideSessionCoordinator`), never entered by tests.
- **No raw speed on the wire or on screen.** The UI shows motion state (moving/stopped) + along-route distance, never a peer's speed.
- **The only new DB object is `ride_roster`** — `security definer`, `set search_path = ''`, `revoke execute … from public`, `grant execute … to authenticated`, **members-only** (`is_ride_member`). No route-vend migration: the route already round-trips in the `rides` row.
- **Display-name gate lives in `GroupRideSession.create/join`, not a view** (deep-link-proof). `DisplayName` caps at ≤40 grapheme clusters to match server `left(p_name, 40)`; blank → **"Rider"** (no trailing period).
- **Amber `#F5C24B`** is the only new colour token; it goes in **pure `AuraPalette`** (`RGBColor`) with a `WCAGContrast` test, surfaced via an `AuraTheme.warning` role. Pink stays destructive-only.
- **Deep-link join** uses the **`DeepLink`** enum (+ `parse` + `AppRouter.handle` arm), routed so the display-name gate and the `AppRouter.isRideActive` guard both apply.
- **Host UI = End only (D12).** One generic join-error message (D13).
- **swiftlint --strict must pass on the whole repo including tests** (lesson from SP2: the `db-tests`/lint CI runs over test files too).

---

## File structure

**AuraCore (pure, new files):**
- `AuraCore/Sources/AuraCore/GroupRide/PeerBearing.swift` — heading from consecutive coordinates.
- `AuraCore/Sources/AuraCore/GroupRide/PeerDistance.swift` — signed along-route gap + formatted label.
- `AuraCore/Sources/AuraCore/GroupRide/DisplayName.swift` — validate/normalize.
- `AuraCore/Sources/AuraCore/GroupRide/GroupRosterViewData.swift` — `[RidePeer]` + `nameMap` → ordered rows.
- Modify `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift` — add `amber`.
- Modify `AuraCore/Sources/AuraCore/Navigation/DeepLink.swift` — add `.join(JoinCode)`.
- Modify `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift` — add `.groupRide(GroupRideEntry)`; new `GroupRideEntry`.

**AuraKit (owner + seam):**
- `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift` — the `@Observable` owner.
- Modify `AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift` — add `currentUserID`, `roster`, `JoinedRide`, `RosterMember`.
- Modify `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` — conform + fake names/route.

**Aura app target (SwiftUI + live conformer):**
- Modify `Aura/Sources/Sync/SupabaseGroupRideBackend.swift` — decode route, `roster`, `currentUserID`.
- `Aura/Sources/Theme/AuraTheme.swift` — add `warning` role.
- `Aura/Sources/GroupRide/GroupRideFlowView.swift` — owns the session, switches on `phase`.
- `Aura/Sources/GroupRide/GroupLobbyView.swift`, `GroupRideJoinView.swift`, `GroupRideMapOverlay.swift`, `GroupRosterSheet.swift`, `GroupToastHost.swift`, `GroupNavigateContainer.swift`.
- `Aura/Sources/GroupRide/DisplayNameStore.swift`, `DisplayNameEditor.swift`.
- Modify `Aura/Sources/Plan/RoutePreviewView.swift` (create action), `Aura/Sources/Plan/PlanView.swift` (join entry), `Aura/Sources/App/AppRouter.swift` (deep-link arm + `pendingJoin`), `Aura/Sources/App/RootView`/`AuraApp.swift` (`.groupRide` destination), `Aura/Sources/Settings/SettingsView.swift` (name editor row).

**Supabase:**
- `supabase/migrations/0016_ride_roster.sql`, `supabase/tests/0016_ride_roster_test.sql`.

---

## Task 1: `ride_roster` RPC + pgTAP

**Files:**
- Create: `supabase/migrations/0016_ride_roster.sql`
- Create: `supabase/tests/0016_ride_roster_test.sql`

**Interfaces:**
- Produces: `public.ride_roster(p_ride_id uuid) returns table(user_id uuid, display_name text, role text)` — members-only. Consumed by `SupabaseGroupRideBackend.roster` (Task 11).

- [ ] **Step 1: Write the migration**

`supabase/migrations/0016_ride_roster.sql`:
```sql
-- SP3: members-only roster read (user_id, display_name, role) for the live group-ride UI.
-- Names never travel on the realtime wire; the UI fetches them here and overlays them onto
-- the broadcast peers. Gated by is_ride_member (matches SP1); no new table, reads members+profiles.
create function public.ride_roster(p_ride_id uuid)
returns table(user_id uuid, display_name text, role text)
language sql
stable
security definer
set search_path = ''
as $$
  select m.user_id, p.display_name, m.role
  from public.ride_members m
  join public.profiles p on p.id = m.user_id
  where m.ride_id = p_ride_id
    and (select public.is_ride_member(p_ride_id));
$$;
revoke execute on function public.ride_roster(uuid) from public;
grant execute on function public.ride_roster(uuid) to authenticated;
```

- [ ] **Step 2: Write the pgTAP test**

`supabase/tests/0016_ride_roster_test.sql` (mirrors `supabase/tests/0006_expiry_test.sql`; a `pg_temp` SECURITY DEFINER helper switches JWT claims like the SP2 tests):
```sql
begin;
select plan(3);
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','host@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','member@test.dev'),
  ('00000000-0000-0000-0000-000000000000','cccccccc-0000-0000-0000-000000000003','authenticated','authenticated','outsider@test.dev');
update public.profiles set display_name = 'Mike'   where id = 'aaaaaaaa-0000-0000-0000-000000000001';
update public.profiles set display_name = 'Sara'   where id = 'bbbbbbbb-0000-0000-0000-000000000002';

create function pg_temp.roster_flow(out member_rows int, out has_names boolean, out outsider_rejected boolean)
language plpgsql security definer set search_path = '' as $$
declare rid uuid; code text;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  -- Capture the join_code UNDER HOST CLAIMS: rides RLS (is_ride_member) hides the row from
  -- the not-yet-member, so reading join_code after switching claims would return nothing.
  select id, join_code into rid, code from public.create_ride('{}'::jsonb);
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  perform public.join_ride(code);
  -- host reads the roster: 2 rows, names present
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select count(*)::int into member_rows from public.ride_roster(rid);
  select bool_and(display_name in ('Mike','Sara')) into has_names from public.ride_roster(rid);
  -- outsider reads: members-only guard -> 0 rows (is_ride_member false)
  perform set_config('request.jwt.claims','{"sub":"cccccccc-0000-0000-0000-000000000003"}', true);
  outsider_rejected := (select count(*) from public.ride_roster(rid)) = 0;
end; $$;

create temp table rf as select * from pg_temp.roster_flow();
select is((select member_rows from rf), 2, 'roster returns one row per member');
select is((select has_names from rf), true, 'roster returns display names');
select is((select outsider_rejected from rf), true, 'non-member gets no rows (members-only)');
select * from finish();
rollback;
```

- [ ] **Step 3: Apply + verify via Supabase MCP** (Docker/pgTAP can't run locally — the `db-tests` CI job is the authoritative gate; validate the function shape live like SP1/SP2 did).

Apply `0016_ride_roster.sql` to project `aura` (ref `wyofhmufnttiqyjkrbxi`) via the migration tool. Then run a self-contained probe (create_ride → join_ride as a 2nd claims-set → ride_roster returns 2 named rows → outsider returns 0). Expected: 2 named rows for a member, 0 for a non-member.

- [ ] **Step 4: Commit**
```bash
git add supabase/migrations/0016_ride_roster.sql supabase/tests/0016_ride_roster_test.sql
git commit -m "feat(db): ride_roster members-only RPC (SP3 names) + pgTAP (0016)"
```

---

## Task 2: Amber status token (AuraPalette + WCAG guard + AuraTheme role)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift`
- Modify: `Aura/Sources/Theme/AuraTheme.swift`

**Interfaces:**
- Produces: `AuraPalette.amber: RGBColor`, `AuraPalette.inkOnAmber: RGBColor`; `AuraTheme.warning`, `AuraTheme.onWarning: Color`. Consumed by the map overlay + roster (Tasks 13/14).

- [ ] **Step 1: Write the failing contrast test**

Append to `AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift` (mirrors `limeOnBackgroundClearsContrast`):
```swift
@Test func amberClearsGraphicalContrastOnDark() {
    // Amber is a status *dot/pill* colour on the near-black map; graphical/large-text bar is 3:1.
    #expect(WCAGContrast.ratio(AuraPalette.amber, AuraPalette.nearBlack) >= 3.0)
    #expect(WCAGContrast.ratio(AuraPalette.amber, AuraPalette.panel) >= 3.0)
}
@Test func inkOnAmberClearsBodyContrast() {
    // Dark ink on an amber pill must clear body text 4.5:1.
    #expect(WCAGContrast.ratio(AuraPalette.inkOnAmber, AuraPalette.amber) >= 4.5)
}
```

- [ ] **Step 2: Run — verify it fails** (`AuraPalette.amber` undefined).
Run: `swift test --package-path AuraCore --filter WCAGContrastTests` — Expected: FAIL (no member `amber`).

- [ ] **Step 3: Add the tokens**

In `AuraPalette.swift`, after the `pink`/`inkOnPink` lines:
```swift
    public static let amber      = RGBColor(red: 0.961, green: 0.761, blue: 0.294) // #F5C24B  stopped/paused
    public static let inkOnAmber = RGBColor(red: 0.165, green: 0.118, blue: 0.0)   // #2A1E00  ink on amber
```

- [ ] **Step 4: Run — verify pass.** Run: `swift test --package-path AuraCore --filter WCAGContrastTests` — Expected: PASS. (If `amber` on `nearBlack` is < 3.0, lighten it toward `#F7CF6B` and re-run — the test is the gate, not the hex.)

- [ ] **Step 5: Add the theme role**

In `Aura/Sources/Theme/AuraTheme.swift`, after `onDestructive`:
```swift
    static let warning       = rgb(AuraPalette.amber)
    static let onWarning     = rgb(AuraPalette.inkOnAmber)
```

- [ ] **Step 6: Build the app to confirm the role compiles** (delegate to the builder agent; app scheme).

- [ ] **Step 7: Commit**
```bash
git add AuraCore/Sources/AuraCore/Theme/AuraPalette.swift AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift Aura/Sources/Theme/AuraTheme.swift
git commit -m "feat(theme): amber stopped-status token in AuraPalette (WCAG-guarded) + AuraTheme.warning"
```

---

## Task 3: `PeerBearing` (pure heading helper)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/PeerBearing.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/PeerBearingTests.swift`

**Interfaces:**
- Consumes: `Coordinate` (lat/lon).
- Produces: `enum PeerBearing { static func heading(from: Coordinate, to: Coordinate) -> Double }` (degrees, 0 = north, clockwise) and `static func heading(from: Coordinate?, to: Coordinate?) -> Double?` (nil when either is nil or the two are identical). Consumed by the map overlay (Task 13) for the cone.

- [ ] **Step 1: Write the failing tests**
```swift
import Testing
import AuraCore

struct PeerBearingTests {
    @Test func dueEastIsNinety() {
        let h = PeerBearing.heading(from: Coordinate(latitude: 0, longitude: 0),
                                    to: Coordinate(latitude: 0, longitude: 1))
        #expect(abs(h - 90) < 0.5)
    }
    @Test func dueNorthIsZero() {
        let h = PeerBearing.heading(from: Coordinate(latitude: 0, longitude: 0),
                                    to: Coordinate(latitude: 1, longitude: 0))
        #expect(abs(h) < 0.5)
    }
    @Test func identicalPointsHaveNoHeading() {
        let p = Coordinate(latitude: 5, longitude: 5)
        #expect(PeerBearing.heading(from: p, to: p) == nil)
    }
    @Test func nilInputsGiveNil() {
        #expect(PeerBearing.heading(from: nil, to: Coordinate(latitude: 1, longitude: 1)) == nil)
    }
}
```

- [ ] **Step 2: Run — verify it fails.** Run: `swift test --package-path AuraCore --filter PeerBearingTests` — Expected: FAIL (no `PeerBearing`).

- [ ] **Step 3: Implement**
```swift
import Foundation

/// Peer heading derived on-device from two consecutive fixes — the live wire carries no bearing.
/// Degrees clockwise from north. Returns nil when a fix is missing or the two coincide (no
/// meaningful direction), so the map draws no cone rather than a random one.
public enum PeerBearing {
    public static func heading(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
    public static func heading(from a: Coordinate?, to b: Coordinate?) -> Double? {
        guard let a, let b, a != b else { return nil }
        return heading(from: a, to: b)
    }
}
```

- [ ] **Step 4: Run — verify pass.** Run: `swift test --package-path AuraCore --filter PeerBearingTests` — Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/PeerBearing.swift AuraCore/Tests/AuraCoreTests/GroupRide/PeerBearingTests.swift
git commit -m "feat(core): PeerBearing pure heading helper for peer dots (SP3)"
```

---

## Task 4: `PeerDistance` (pure ahead/behind helper)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/PeerDistance.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/PeerDistanceTests.swift`

**Interfaces:**
- Consumes: `RidePeer` (`progressMeters: Double?`, `status`), and a plain **`isImperial: Bool`**. NOTE (reviewer-confirmed): the app's units type is `DistanceUnits` (`.imperial`/`.metric`) and lives in **AuraKit** (`AuraKit/Settings/SettingsStore.swift`), which AuraCore **cannot import** (dependency is one-way AuraKit→AuraCore). So a pure AuraCore helper must NOT reference `DistanceUnits`; it takes a `Bool`. Callers map `settings.units == .imperial` at the AuraKit/app boundary.
- Produces: `enum PeerDistance { static func label(selfProgress: Double, peer: RidePeer, isImperial: Bool) -> String? }`. Returns `nil` for `.awaiting` (no position); a "no signal" sentinel is NOT its job (the row handles `.dropped` copy); for a positioned peer returns e.g. `"0.4 mi ahead"`, `"120 m behind"`, `"even"`.

- [ ] **Step 1: Write the failing tests**
```swift
import Testing
import AuraCore

struct PeerDistanceTests {
    private func peer(_ p: Double?, _ s: PeerStatus) -> RidePeer {
        RidePeer(userID: UUID(), displayName: "x", progressMeters: p, status: s)
    }
    @Test func aheadImperial() {
        let l = PeerDistance.label(selfProgress: 0, peer: peer(804.7, .riding), isImperial: true)
        #expect(l == "0.5 mi ahead")
    }
    @Test func behindMetric() {
        let l = PeerDistance.label(selfProgress: 200, peer: peer(80, .riding), isImperial: false)
        #expect(l == "120 m behind")
    }
    @Test func evenWhenClose() {
        let l = PeerDistance.label(selfProgress: 100, peer: peer(105, .riding), isImperial: false)
        #expect(l == "even")
    }
    @Test func awaitingHasNoDistance() {
        #expect(PeerDistance.label(selfProgress: 0, peer: peer(nil, .awaiting), isImperial: false) == nil)
    }
}
```

- [ ] **Step 2: Run — verify it fails.** Run: `swift test --package-path AuraCore --filter PeerDistanceTests` — Expected: FAIL.

- [ ] **Step 3: Implement** (units math mirrors whatever formatter the app already uses; if a shared `Units` conversion exists in AuraCore, reuse it rather than re-deriving — DRY):
```swift
import Foundation

/// Signed along-route gap between self and a peer, formatted for the roster. Uses the peer's
/// `progressMeters` (already on the wire) — a subtraction, no map query. nil when the peer has
/// no position yet (`.awaiting`); `.dropped` copy is the row's job, not this helper's.
public enum PeerDistance {
    private static let evenBandMeters = 15.0
    public static func label(selfProgress: Double, peer: RidePeer, isImperial: Bool) -> String? {
        guard let p = peer.progressMeters else { return nil }
        let delta = p - selfProgress
        if abs(delta) < evenBandMeters { return "even" }
        let direction = delta > 0 ? "ahead" : "behind"
        let magnitude = abs(delta)
        if isImperial {
            let miles = magnitude / 1609.34
            if miles >= 0.1 { return String(format: "%.1f mi %@", miles, direction) }
            return "\(Int((magnitude / 0.3048).rounded())) ft \(direction)"
        } else {
            if magnitude >= 1000 { return String(format: "%.1f km %@", magnitude / 1000, direction) }
            return "\(Int(magnitude.rounded())) m \(direction)"
        }
    }
}
```

- [ ] **Step 4: Run — verify pass.** (Adjust the rounding to match the app's existing distance formatter if outputs differ; keep the tests as the contract.)

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/PeerDistance.swift AuraCore/Tests/AuraCoreTests/GroupRide/PeerDistanceTests.swift
git commit -m "feat(core): PeerDistance ahead/behind label from progressMeters (SP3)"
```

---

## Task 5: `DisplayName` (pure validation + gate helper)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/DisplayName.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/DisplayNameTests.swift`

**Interfaces:**
- Produces: `enum DisplayName { static func normalized(_ raw: String) -> String?  ; static func forDisplay(_ raw: String) -> String }`. `normalized` trims, returns nil if empty after trim, caps at 40 **grapheme clusters**; `forDisplay` returns `normalized(raw) ?? "Rider"`. The **gate** uses `normalized(...) != nil`. Consumed by `GroupRideSession` (Task 9) and `DisplayNameStore` (Task 12).

- [ ] **Step 1: Write the failing tests**
```swift
import Testing
import AuraCore

struct DisplayNameTests {
    @Test func trimsWhitespace() { #expect(DisplayName.normalized("  Mike  ") == "Mike") }
    @Test func emptyBecomesNil() {
        #expect(DisplayName.normalized("") == nil)
        #expect(DisplayName.normalized("   ") == nil)
    }
    @Test func capsAt40Graphemes() {
        let long = String(repeating: "a", count: 60)
        #expect(DisplayName.normalized(long)?.count == 40)
    }
    @Test func doesNotSplitGraphemeCluster() {
        // 40 flags (each a multi-scalar grapheme) must not be cut mid-cluster.
        let flags = String(repeating: "🇺🇸", count: 45)
        let n = DisplayName.normalized(flags)!
        #expect(n.count == 40)                      // 40 whole clusters
        #expect(n.unicodeScalars.count == 80)       // no half-flag tail
    }
    @Test func fallbackIsRiderNoPeriod() { #expect(DisplayName.forDisplay("   ") == "Rider") }
}
```

- [ ] **Step 2: Run — verify it fails.** Run: `swift test --package-path AuraCore --filter DisplayNameTests` — Expected: FAIL.

- [ ] **Step 3: Implement**
```swift
import Foundation

/// Display-name validation, shared by the create/join gate and the settings editor. Grapheme-aware
/// 40-cap matches the server's `left(p_name, 40)` so what you type equals what the crew sees.
public enum DisplayName {
    public static let maxGraphemes = 40
    public static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxGraphemes))   // String.prefix is grapheme-cluster based
    }
    public static func forDisplay(_ raw: String) -> String { normalized(raw) ?? "Rider" }
}
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/DisplayName.swift AuraCore/Tests/AuraCoreTests/GroupRide/DisplayNameTests.swift
git commit -m "feat(core): DisplayName validation (40-grapheme cap, Rider fallback) for the crew gate (SP3)"
```

---

## Task 6: `GroupRosterViewData` (pure roster transform)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/GroupRosterViewData.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/GroupRosterViewDataTests.swift`

**Interfaces:**
- Consumes: `[RidePeer]`, `nameMap: [UUID: String]`, `selfUserID: UUID`, `isImperial: Bool` (same layering reason as Task 4 — no `DistanceUnits` in AuraCore), and (for distance) self's `progressMeters`. Uses `PeerDistance`, `DisplayName`, `PeerStatus`.
- Produces:
```swift
public struct RosterRow: Equatable, Sendable, Identifiable {
    public let id: UUID              // userID
    public let name: String
    public let isSelf: Bool
    public let status: PeerStatus
    public let distanceLabel: String?   // nil for self and awaiting; "no signal" for dropped
}
public enum GroupRosterViewData {
    public static func rows(peers: [RidePeer], nameMap: [UUID: String],
                            selfUserID: UUID, selfProgress: Double, isImperial: Bool) -> [RosterRow]
}
```
Ordering: leader-first by `progressMeters` (desc, nil last); **self always present** (synthesize a self row if not in `peers`). Name resolves `nameMap[id]` → peer.displayName → "Rider". `.dropped` → `distanceLabel = "no signal"`; self → nil.

- [ ] **Step 1: Write the failing tests**
```swift
import Testing
import AuraCore

struct GroupRosterViewDataTests {
    let me = UUID(), sara = UUID(), jordan = UUID()
    private func peer(_ id: UUID, _ p: Double?, _ s: PeerStatus, _ name: String = "") -> RidePeer {
        RidePeer(userID: id, displayName: name, progressMeters: p, status: s)
    }
    @Test func ordersLeaderFirstAndPinsSelf() {
        let rows = GroupRosterViewData.rows(
            peers: [peer(me, 100, .riding), peer(sara, 300, .riding), peer(jordan, 50, .stopped)],
            nameMap: [sara: "Sara", jordan: "Jordan"], selfUserID: me, selfProgress: 100, isImperial: false)
        #expect(rows.map(\.id) == [sara, me, jordan])       // 300, 100(self), 50
        #expect(rows.first { $0.isSelf }?.id == me)
    }
    @Test func nameMapOverridesBlank_elseRider() {
        let rows = GroupRosterViewData.rows(
            peers: [peer(sara, 10, .riding)], nameMap: [:], selfUserID: me, selfProgress: 0, isImperial: false)
        #expect(rows.first { $0.id == sara }?.name == "Rider")   // no name yet
    }
    @Test func droppedShowsNoSignal() {
        let rows = GroupRosterViewData.rows(
            peers: [peer(jordan, 10, .dropped)], nameMap: [jordan: "Jordan"], selfUserID: me, selfProgress: 0, isImperial: false)
        #expect(rows.first { $0.id == jordan }?.distanceLabel == "no signal")
    }
    @Test func synthesizesSelfWhenAbsent() {
        let rows = GroupRosterViewData.rows(
            peers: [], nameMap: [:], selfUserID: me, selfProgress: 0, isImperial: false)
        #expect(rows.map(\.id) == [me])
    }
}
```

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement**
```swift
import Foundation

public struct RosterRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let isSelf: Bool
    public let status: PeerStatus
    public let distanceLabel: String?
}

public enum GroupRosterViewData {
    private static let selfLabel = "You"
    private static let noSignalLabel = "no signal"
    public static func rows(peers: [RidePeer], nameMap: [UUID: String],
                            selfUserID: UUID, selfProgress: Double, isImperial: Bool) -> [RosterRow] {
        var all = peers
        if !all.contains(where: { $0.userID == selfUserID }) {
            all.append(RidePeer(userID: selfUserID, displayName: "",
                                progressMeters: selfProgress, status: .riding))
        }
        let sorted = all.sorted {
            switch ($0.progressMeters, $1.progressMeters) {
            case let (a?, b?): return a > b
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return $0.userID.uuidString < $1.userID.uuidString
            }
        }
        return sorted.map { peer in
            let isSelf = peer.userID == selfUserID
            let name = isSelf ? selfLabel
                : DisplayName.forDisplay(nameMap[peer.userID] ?? peer.displayName)
            let distance: String?
            if isSelf { distance = nil }
            else if peer.status == .dropped { distance = noSignalLabel }
            else { distance = PeerDistance.label(selfProgress: selfProgress, peer: peer, isImperial: isImperial) }
            return RosterRow(id: peer.userID, name: name, isSelf: isSelf,
                             status: peer.status, distanceLabel: distance)
        }
    }
}
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/GroupRosterViewData.swift AuraCore/Tests/AuraCoreTests/GroupRide/GroupRosterViewDataTests.swift
git commit -m "feat(core): GroupRosterViewData ordered rows + name overlay (SP3)"
```

---

## Task 7: `DeepLink.join` + `AppRoute.groupRide`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Navigation/DeepLink.swift`
- Modify: `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`
- Create: `AuraCore/Tests/AuraCoreTests/DeepLinkJoinTests.swift`

**Interfaces:**
- Produces: `DeepLink.join(JoinCode)` parsed from `aura://join?code=XXXXXXXX`; `AppRoute.groupRide(GroupRideEntry)` where `public enum GroupRideEntry: Hashable, Sendable { case create(Route); case join(JoinCode) }`. Consumed by `AppRouter` (Task 16/17) and navigation destination.

- [ ] **Step 1: Write the failing tests**
```swift
import Testing
import AuraCore

struct DeepLinkJoinTests {
    @Test func parsesValidJoinCode() {
        let url = URL(string: "aura://join?code=7K2Q9FX3")!
        #expect(DeepLink.parse(url) == .join(JoinCode(rawValue: "7K2Q9FX3")!))
    }
    @Test func rejectsInvalidCode() {
        // lowercase / ambiguous glyphs fail JoinCode validation -> nil (no-op link)
        #expect(DeepLink.parse(URL(string: "aura://join?code=abc")!) == nil)
    }
    @Test func rejectsMissingCode() {
        #expect(DeepLink.parse(URL(string: "aura://join")!) == nil)
    }
}
```

- [ ] **Step 2: Run — verify it fails.** Run: `swift test --package-path AuraCore --filter DeepLinkJoinTests` — Expected: FAIL.

- [ ] **Step 3: Implement**

In `DeepLink.swift`, add the case and parse arm:
```swift
    case join(JoinCode)
```
add `case "join": return join(from: components)` to the `switch host`, and:
```swift
    private static func join(from components: URLComponents) -> DeepLink? {
        guard let raw = (components.queryItems ?? []).first(where: { $0.name == "code" })?.value,
              let code = JoinCode(rawValue: raw) else { return nil }
        return .join(code)
    }
```
`DeepLink` already `: Equatable` — `JoinCode` is `Equatable`, so `.join` compares for free.

In `AppRoute.swift`, add the entry type + case + `Hashable` arms:
```swift
public enum GroupRideEntry: Hashable, Sendable {
    case create(Route)
    case join(JoinCode)
}
```
add `case groupRide(GroupRideEntry)` to `AppRoute`; in `==` add
`case let (.groupRide(a), .groupRide(b)): return a == b` (needs `Route: Equatable` ✓, `JoinCode: Equatable` ✓ — but `GroupRideEntry` must hash by `Route.id`, so give it a manual `Hashable`: `.create` → combine `route.id`, `.join` → combine `code.rawValue`); and a `hash(into:)` arm `case let .groupRide(e): hasher.combine(3); hasher.combine(e)`.

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/Navigation/DeepLink.swift AuraCore/Sources/AuraCore/Navigation/AppRoute.swift AuraCore/Tests/AuraCoreTests/DeepLinkJoinTests.swift
git commit -m "feat(core): aura://join deep link + AppRoute.groupRide entry (SP3)"
```

---

## Task 8: `GroupRideBackend` seam extensions + in-memory fake

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift`
- **Modify** (NOT create — it already exists): `AuraCore/Tests/AuraKitTests/GroupRide/InMemoryGroupRideBackendTests.swift` — the file has existing tests (e.g. `createThenJoinReturnsSameRide` asserting `joined.id == ride.id`). Because `joinRide` now returns `JoinedRide`, update those assertions to `joined.ride.id`, and add the new test below. Do NOT overwrite the file.

**Interfaces:**
- Produces on the protocol:
```swift
func currentUserID() async throws -> UUID
func joinRide(code: JoinCode) async throws -> JoinedRide      // CHANGED return type (was GroupRide)
func roster(rideID: UUID) async throws -> [RosterMember]
```
with `public struct JoinedRide: Sendable { public let ride: GroupRide; public let route: Data }` and `public struct RosterMember: Equatable, Sendable { public let userID: UUID; public let displayName: String; public let role: RideMember.Role }`. **`RideMember.Role`** (`{ case host, member }`) is the real, existing role enum — there is no `GroupRide.Role`. Also add a case to the existing `GroupRideError` for the create size limit: `case routeTooLarge` (§7 >256 KB state). (Host keeps its own route locally, so `createRide` still returns `GroupRide`.) Consumed by `GroupRideSession` (Tasks 9/10a/10b) and the live conformer (Task 11).

- [ ] **Step 1: Write the failing tests** (the fake must round-trip route + return named roster + self id)
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct InMemoryGroupRideBackendTests {
    @Test func joinReturnsStoredRouteAndRoster() async throws {
        let host = InMemoryGroupRideBackend()
        try await host.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let routeBytes = Data("{\"hello\":1}".utf8)
        let ride = try await host.createRide(route: routeBytes)

        let guest = InMemoryGroupRideBackend(sharing: host)
        try await guest.signIn(idToken: "t2", nonce: "n2", displayName: "Sara")
        let joined = try await guest.joinRide(code: ride.joinCode)
        #expect(joined.route == routeBytes)

        let roster = try await host.roster(rideID: ride.id)
        #expect(Set(roster.map(\.displayName)) == ["Mike", "Sara"])
        let selfID = try await guest.currentUserID()
        #expect(roster.contains { $0.userID == selfID })
    }
}
```

- [ ] **Step 2: Run — verify it fails.** Run: `swift test --package-path AuraCore --filter InMemoryGroupRideBackendTests` — Expected: FAIL.

- [ ] **Step 3: Implement the protocol change + fake**

`GroupRideBackend.swift`: add the two structs, add `currentUserID`, `roster`, change `joinRide` return to `JoinedRide`, add `case routeTooLarge` to `GroupRideError`. `RosterMember.role` uses the existing `RideMember.Role`.

`InMemoryGroupRideBackend.swift`: extend `Store` with `routes: [UUID: Data] = [:]`, `names: [UUID: String] = [:]`, test spies `leaveCalled = false` and `forceCreateError: GroupRideError? = nil`; keep `currentUser`. `signIn` records `names[currentUser!] = DisplayName.forDisplay(displayName ?? "")` (already `import AuraCore`). `createRide` throws `store.forceCreateError` first if set (so the Task-9 too-large test works), then stores `store.routes[ride.id] = route`. `joinRide` returns `JoinedRide(ride: ride, route: store.routes[rideID] ?? Data())`. `leaveRide` also sets `store.leaveCalled = true` (so Task 9's auto-leave test can assert it). Add:
```swift
public func currentUserID() async throws -> UUID {
    guard let uid = currentUser else { throw GroupRideError.notAuthenticated }
    return uid
}
public func roster(rideID: UUID) async throws -> [RosterMember] {
    (store.members[rideID] ?? []).map {
        RosterMember(userID: $0, displayName: store.names[$0] ?? "Rider",
                     role: $0 == store.rides[rideID]?.hostID ? .host : .member)
    }
}
```
Also update the **existing** tests in the file: any `joined.id`/`joined.status` becomes `joined.ride.id`/`joined.ride.status`.

- [ ] **Step 4: Run — verify pass.** Run: `swift test --package-path AuraCore --filter InMemoryGroupRideBackendTests`.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift AuraCore/Tests/AuraKitTests/GroupRide/InMemoryGroupRideBackendTests.swift
git commit -m "feat(kit): GroupRideBackend gains currentUserID/roster + JoinedRide(route); fake round-trips (SP3)"
```

---

## Task 9: `GroupRideSession` — lifecycle (create / join / gate / phase)

**Files:**
- Create: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleTests.swift`

**Interfaces:**
- Consumes: `GroupRideBackend`, `RideSessionTransport`, `LiveShareCadence`, `Route` (Codable), `DisplayName`, `JoinedRide`.
- Produces (`@MainActor @Observable public final class GroupRideSession`):
```swift
public enum Phase: Equatable, Sendable {
    case idle, lobby, riding, ended, routeUnavailable, createFailed, needsDisplayName
}
public private(set) var phase: Phase
public private(set) var isHost: Bool
public private(set) var rideID: UUID?
public private(set) var joinCode: JoinCode?
public private(set) var route: Route?          // the route to navigate (host's own or decoded on join)
public init(backend: any GroupRideBackend, transport: any RideSessionTransport,
            displayNameProvider: @escaping @Sendable () -> String, cadence: LiveShareCadence = .init())
public func create(route: Route) async
public func join(code: JoinCode) async
public func startRiding()      // lobby -> riding (host)
```
- **Gate:** `create`/`join` set `phase = .needsDisplayName` and return early if `DisplayName.normalized(displayNameProvider()) == nil` (covers both entry points; the join path is the deep-link-reachable one, so its gate is load-bearing).
- **selfUserID:** `JoinedRide` has NO `selfUserID` field — obtain it from `try await backend.currentUserID()`; `isHost = (ride.hostID == selfUserID)`.
- **create:** on a `GroupRideError.routeTooLarge` from the backend (the >256 KB `rides.route` check), set `phase = .createFailed` (§7).
- **join:** decode `JoinedRide.route` via `JSONDecoder().decode(Route.self, from:)`; decode failure → `phase = .routeUnavailable` **and** `try? await backend.leaveRide(rideID:)` to free the slot. On success a joiner goes straight to `.riding` (D3 rolling join — never blocked in a lobby).

- [ ] **Step 1: Write the failing tests**
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideSessionLifecycleTests {
    private func route() -> Route {
        Route(origin: .init(latitude: 0, longitude: 0), destination: .init(latitude: 1, longitude: 1),
              waypoints: [], geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
              profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0)
    }
    private func make(name: String = "Mike") async throws -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: name)
        let s = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                 displayNameProvider: { name })
        return (s, backend)
    }
    @Test func createEntersLobbyAsHost() async throws {
        let (s, _) = try await make()
        await s.create(route: route())
        #expect(s.phase == .lobby)
        #expect(s.isHost == true)
        #expect(s.joinCode != nil)
        #expect(s.route != nil)
    }
    @Test func startRidingTransitions() async throws {
        let (s, _) = try await make()
        await s.create(route: route())
        s.startRiding()
        #expect(s.phase == .riding)
    }
    // Builds a signed-in guest session sharing the host's store, ready to join.
    private func guest(sharing host: InMemoryGroupRideBackend, name: String) async throws
        -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend(sharing: host)
        try await backend.signIn(idToken: "t2", nonce: "n2", displayName: name)
        return (GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                 displayNameProvider: { name }), backend)
    }
    @Test func joinEntersRidingAsMemberWithRoute() async throws {
        let (host, hostBackend) = try await make(name: "Mike")
        await host.create(route: route())
        let (guest, _) = try await guest(sharing: hostBackend, name: "Sara")
        await guest.join(code: host.joinCode!)
        #expect(guest.phase == .riding)          // D3 rolling join — never parked in a lobby
        #expect(guest.isHost == false)
        #expect(guest.route?.geometry.count == 2)
    }
    @Test func joinWithCorruptRouteEntersRouteUnavailableAndLeaves() async throws {
        let (host, hostBackend) = try await make(name: "Mike")
        await host.create(route: route())
        // Corrupt the stored route bytes so JSONDecoder().decode(Route.self) fails on join.
        hostBackend.store.routes[host.rideID!] = Data("not-a-route".utf8)
        let (guest, guestBackend) = try await guest(sharing: hostBackend, name: "Sara")
        await guest.join(code: host.joinCode!)
        #expect(guest.phase == .routeUnavailable)
        #expect(guestBackend.store.leaveCalled == true)   // auto-left to free the slot
    }
    @Test func createTooLargeEntersCreateFailed() async throws {
        let (s, backend) = try await make()
        backend.store.forceCreateError = .routeTooLarge   // simulates the >256 KB rides.route check
        await s.create(route: route())
        #expect(s.phase == .createFailed)
    }
    @Test func emptyNameGatesCreate() async throws {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "")
        let s = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                 displayNameProvider: { "   " })
        await s.create(route: route())
        #expect(s.phase == .needsDisplayName)
    }
    @Test func emptyNameGatesJoin() async throws {          // the deep-link-reachable gate
        let (host, hostBackend) = try await make(name: "Mike")
        await host.create(route: route())
        let (guest, _) = try await guest(sharing: hostBackend, name: "")   // provider returns ""
        await guest.join(code: host.joinCode!)
        #expect(guest.phase == .needsDisplayName)
    }
}
```
(Implementation note for the test: the guest `GroupRideSession` needs its backend signed in before `join`; wire the fake so `currentUserID()` works. Keep the test faithful to the real call order.)

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement the lifecycle** (no ticker yet — Task 10 adds the live layer; `join` on success sets `phase = .riding` for the joiner and `.lobby`→`.riding` via `startRiding` for the host). Construct the inner `RideSession(rideID:selfUserID:transport:cadence:)` and stash it. `isHost = (ride.hostID == selfUserID)`. On join success, fetch `route` decode; on failure set `.routeUnavailable` + leave.

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleTests.swift
git commit -m "feat(kit): GroupRideSession lifecycle — create/join/gate/phase (SP3)"
```

---

## Task 10a: `GroupRideSession` — tick seam, snapshot, reconnect, end/leave

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionTickTests.swift`

**Interfaces:**
- Produces (added to `GroupRideSession`):
```swift
public private(set) var peers: [RidePeer]        // snapshot of the inner RideSession
public private(set) var isLive: Bool
private var currentLifecycle: RideLifecycle = .foreground   // RideLifecycle cases: .foreground / .background
public func tick(now: Date) async                // SOLE time entry: publishIfDue + stalenessTick + snapshot
public func ingest(_ event: TransportEvent) async  // forwards to inner RideSession, then snapshots
func startTicker()                               // PRODUCTION-ONLY: Date()/Task.sleep loop calling tick(now:)
public func end() async
public func leave() async
```
Both `tick` and `ingest` end by copying `session.peers`/`session.isLive` into the observable stored props (so SwiftUI repaints promptly, not only on the next tick). `end()`/`leave()` call the SP1 RPCs and set `phase = .ended`, then tear down (`session.stop()`, cancel ticker).

- [ ] **Step 1: Write the failing tests** (deterministic — drive `ingest`/`tick`, never `startTicker`)
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideSessionTickTests {
    private func ridingHost() async throws -> (GroupRideSession, InMemoryRideSessionTransport, UUID) {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let selfID = try await backend.currentUserID()
        let transport = InMemoryRideSessionTransport()
        let s = GroupRideSession(backend: backend, transport: transport, displayNameProvider: { "Mike" })
        await s.create(route: Route(origin: .init(latitude: 0, longitude: 0),
            destination: .init(latitude: 1, longitude: 1), waypoints: [],
            geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
            profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0))
        s.startRiding()
        return (s, transport, selfID)
    }
    private func position(_ id: UUID, _ meters: Double, at t: TimeInterval) -> TransportEvent {
        .position(LivePositionPayload(userID: id, coordinate: .init(latitude: 1, longitude: 1),
                                      progressMeters: meters, recordedAt: Date(timeIntervalSince1970: t),
                                      motionState: .moving))
    }
    @Test func ingestSnapshotsPeersForObservation() async throws {
        let (s, _, _) = try await ridingHost()
        let peer = UUID()
        await s.ingest(position(peer, 10, at: 100))
        #expect(s.peers.contains { $0.userID == peer })
    }
    @Test func disconnectThenConnectReseeds() async throws {
        let (s, transport, _) = try await ridingHost()
        await s.ingest(.disconnected(nil))
        #expect(s.isLive == false)
        let seeded = UUID()
        transport.snapshotResult = [LivePositionPayload(userID: seeded, coordinate: .init(latitude: 2, longitude: 2),
            progressMeters: 42, recordedAt: Date(timeIntervalSince1970: 200), motionState: .moving)]
        await s.ingest(.connected)
        #expect(s.isLive == true)
        #expect(s.peers.contains { $0.userID == seeded })   // re-seeded from the snapshot
    }
    @Test func endTransitionsToEnded() async throws {
        let (s, _, _) = try await ridingHost()
        await s.end()
        #expect(s.phase == .ended)
    }
    @Test func tickDoesNotUseWallClock() async throws {
        // Purely exercises the injected-time entry; a fixed `now` must be accepted with no real waiting.
        let (s, _, _) = try await ridingHost()
        await s.tick(now: Date(timeIntervalSince1970: 500))
        #expect(s.phase == .riding)
    }
}
```

- [ ] **Step 2: Run — verify it fails.** Run: `swift test --package-path AuraCore --filter GroupRideSessionTickTests` — Expected: FAIL.

- [ ] **Step 3: Implement.**
- `tick(now:)`: `await session.publishIfDue(now: now, lifecycle: currentLifecycle)`; `session.stalenessTick(now: now)`; `self.peers = session.peers; self.isLive = session.isLive`.
- `ingest(_:)`: `await session.ingest(event)`; then `self.peers = session.peers; self.isLive = session.isLive`. (Membership/toast logic is added in Task 10b — here `ingest` only forwards + snapshots.)
- `startTicker()` (production only), mirroring `RideSessionCoordinator`:
```swift
func startTicker() {
    tickerTask = Task { [weak self] in
        while !Task.isCancelled {
            guard let self else { return }
            await self.tick(now: Date())
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
```
- `end()` → `try? await backend.endRide(rideID:)`; `phase = .ended`; `session.stop()`; `tickerTask?.cancel()`. `leave()` → `try? await backend.leaveRide(rideID:)`; same teardown. When `startRiding()`/`join` enters `.riding` in production, call `await session.start(roster:)` + `startTicker()`; tests drive `ingest`/`tick` directly and never start the ticker.

- [ ] **Step 4: Run — verify pass.** Confirm no `Date()`/`Task.sleep` in the tested path (only in `startTicker`, untouched by tests).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionTickTests.swift
git commit -m "feat(kit): GroupRideSession tick seam + snapshot + reconnect + end/leave (SP3)"
```

---

## Task 10b: `GroupRideSession` — membership toasts + nameMap refresh

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionToastTests.swift`

**Interfaces:**
- Produces (added to `GroupRideSession`):
```swift
public private(set) var nameMap: [UUID: String]   // userID -> display name, from ride_roster
public private(set) var toasts: [GroupToastEvent]  // append-only; the UI drains it
```
and `public enum GroupToastEvent: Equatable, Sendable { case joined(String), left(String), hostEnded }` (in AuraKit). `ingest` now also: for a `.position(p)` whose `p.userID` is NOT in `nameMap` → `await refreshRoster()` (throttled by an in-flight guard so a burst = one fetch) → if a name resolved, append `.joined(name)`; for `.memberLeft(id)` → append `.left(nameMap[id] ?? "Rider")`. **No toast is emitted for a motion-state change on an already-known peer (D11).** `refreshRoster()` merges `try? await backend.roster(rideID:)` into `nameMap`. `end()` appends `.hostEnded` for the members' path when the ended signal arrives (host's own `end()` does not toast itself).

- [ ] **Step 1: Write the failing tests** (real bodies — these guard D11 and Finding #1)
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideSessionToastTests {
    // Host session in .riding, plus a guest who has actually joined (so backend.roster names them).
    private func hostWithJoinedGuest(named guestName: String)
        async throws -> (GroupRideSession, UUID) {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let host = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                    displayNameProvider: { "Mike" })
        await host.create(route: Route(origin: .init(latitude: 0, longitude: 0),
            destination: .init(latitude: 1, longitude: 1), waypoints: [],
            geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
            profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0))
        host.startRiding()
        let guestBackend = InMemoryGroupRideBackend(sharing: backend)
        try await guestBackend.signIn(idToken: "t2", nonce: "n2", displayName: guestName)
        let guestID = try await guestBackend.currentUserID()
        _ = try await guestBackend.joinRide(code: host.joinCode!)   // now a member with a name
        return (host, guestID)
    }
    private func position(_ id: UUID, _ motion: MotionState, at t: TimeInterval) -> TransportEvent {
        .position(LivePositionPayload(userID: id, coordinate: .init(latitude: 1, longitude: 1),
                                      progressMeters: 10, recordedAt: Date(timeIntervalSince1970: t),
                                      motionState: motion))
    }
    @Test func newPeerPositionEmitsJoinedToastWithResolvedName() async throws {
        let (host, sara) = try await hostWithJoinedGuest(named: "Sara")
        await host.ingest(position(sara, .moving, at: 100))
        #expect(host.nameMap[sara] == "Sara")
        #expect(host.toasts.contains(.joined("Sara")))
    }
    @Test func unnamedPeerBecomesNamedWithinOneRefresh() async throws {
        // Finding #1 / §13 "nobody appears blank": after a new peer's first position, the roster
        // refresh must resolve the real name (not leave it blank).
        let (host, sara) = try await hostWithJoinedGuest(named: "Sara")
        #expect(host.nameMap[sara] == nil)               // unknown before any position
        await host.ingest(position(sara, .moving, at: 100))
        #expect(host.nameMap[sara] == "Sara")            // resolved by the triggered refresh
    }
    @Test func motionChangeEmitsNoToast() async throws {   // D11 — the load-bearing invariant
        let (host, sara) = try await hostWithJoinedGuest(named: "Sara")
        await host.ingest(position(sara, .moving, at: 100))   // first sighting: one .joined
        let afterJoin = host.toasts.count
        await host.ingest(position(sara, .stopped, at: 101))  // motion change only
        await host.ingest(position(sara, .moving, at: 102))
        #expect(host.toasts.count == afterJoin)               // no new toast
    }
    @Test func memberLeftEmitsLeftToastAndRemovesPeer() async throws {
        let (host, sara) = try await hostWithJoinedGuest(named: "Sara")
        await host.ingest(position(sara, .moving, at: 100))   // learn Sara
        await host.ingest(.memberLeft(sara))
        #expect(host.toasts.contains(.left("Sara")))
        #expect(!host.peers.contains { $0.userID == sara })
    }
}
```

- [ ] **Step 2: Run — verify it fails.** Run: `swift test --package-path AuraCore --filter GroupRideSessionToastTests` — Expected: FAIL.

- [ ] **Step 3: Implement.** Extend `ingest` (from 10a): before the snapshot, branch on the event —
```swift
switch event {
case .position(let p) where nameMap[p.userID] == nil:
    await refreshRoster()
    if let name = nameMap[p.userID] { toasts.append(.joined(name)) }
case .memberLeft(let id):
    toasts.append(.left(nameMap[id] ?? "Rider"))
default: break
}
await session.ingest(event)
peers = session.peers; isLive = session.isLive
```
`refreshRoster()` guards re-entrancy (`guard !isRefreshingRoster else { return }`) and merges `backend.roster(rideID:)` names into `nameMap`. Note the `.position where nameMap[...] == nil` guard is precisely what makes a *motion change on a known peer* emit nothing (D11).

- [ ] **Step 4: Run — verify pass.** Run: `swift test --package-path AuraCore --filter GroupRideSessionToastTests`, then the full package: `swift test --package-path AuraCore` — all green.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionToastTests.swift
git commit -m "feat(kit): GroupRideSession membership toasts + nameMap refresh (D11-guarded) (SP3)"
```

---

## Task 11: `SupabaseGroupRideBackend` — decode route, roster, currentUserID

**Files:**
- Modify: `Aura/Sources/Sync/SupabaseGroupRideBackend.swift`

**Interfaces:**
- Consumes: the Task-8 protocol shape + Task-1 `ride_roster` RPC.
- Produces: the live conformance. `joinRide` returns `JoinedRide(ride:route:)`; `roster` calls `ride_roster`; `currentUserID` reads the auth session.

- [ ] **Step 1: Add `route` to the decoded row**

In `GroupRideRow`, add `let route: AnyJSON` (CodingKey `route`) and a helper `func routeData() throws -> Data { try JSONEncoder().encode(route) }`. `toDomain()` unchanged (returns `GroupRide`).

- [ ] **Step 2: Return `JoinedRide` from `joinRide`**
```swift
public nonisolated func joinRide(code: JoinCode) async throws -> JoinedRide {
    do {
        let row: GroupRideRow = try await client
            .rpc("join_ride", params: ["p_code": code.rawValue]).single().execute().value
        return JoinedRide(ride: try row.toDomain(), route: try row.routeData())
    } catch { throw GroupRideError.joinFailed }
}
```

- [ ] **Step 2b: Map the create size-limit error to `routeTooLarge`**

`createRide` currently lets any RPC error propagate. Wrap it so the `rides.route` `pg_column_size < 262144` check-constraint violation becomes the typed `.routeTooLarge` that `GroupRideSession.create` maps to `.createFailed`:
```swift
public nonisolated func createRide(route: Data) async throws -> GroupRide {
    let routeJSON = try JSONDecoder().decode(AnyJSON.self, from: route)
    do {
        let row: GroupRideRow = try await client
            .rpc("create_ride", params: ["p_route": routeJSON]).single().execute().value
        return try row.toDomain()
    } catch let error as PostgrestError where error.message.contains("rides_route_check")
                                          || error.message.lowercased().contains("check constraint") {
        throw GroupRideError.routeTooLarge
    }
}
```
(Confirm the `PostgrestError` type/`.message` accessor against the pinned supabase-swift; if the check-constraint name differs, match on the size-check substring the server actually returns — verify with one oversized probe via MCP.)

- [ ] **Step 3: Implement `roster` + `currentUserID`**
```swift
private nonisolated struct RosterRow: Decodable {
    let userID: UUID; let displayName: String; let role: String
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case displayName = "display_name"; case role }
}
public nonisolated func roster(rideID: UUID) async throws -> [RosterMember] {
    let rows: [RosterRow] = try await client
        .rpc("ride_roster", params: ["p_ride_id": rideID.uuidString]).execute().value
    return rows.map { RosterMember(userID: $0.userID, displayName: $0.displayName,
                                   role: $0.role == "host" ? .host : .member) }
}
public nonisolated func currentUserID() async throws -> UUID {
    try await client.auth.session.user.id
}
```
(Confirm the supabase-swift accessor name — `client.auth.session` is `async throws` and yields `Session.user.id`. If the installed SDK exposes `client.auth.currentUser?.id`, use that with a `notAuthenticated` throw on nil. Verify against the pinned SDK before finalizing.)

- [ ] **Step 4: Build-verify** (delegate to the builder agent — this can't be unit-tested locally; the pgTAP in Task 1 + CI cover the DB, and the app build confirms the API usage compiles against the real SDK).
Expected: app build SUCCEEDS.

- [ ] **Step 5: Commit**
```bash
git add Aura/Sources/Sync/SupabaseGroupRideBackend.swift
git commit -m "feat(sync): SupabaseGroupRideBackend decodes route + ride_roster + currentUserID (SP3)"
```

---

## Task 12: Display-name store + editor + settings + first-run prompt

**Files:**
- Create: `Aura/Sources/GroupRide/DisplayNameStore.swift`
- Create: `Aura/Sources/GroupRide/DisplayNameEditor.swift`
- Modify: `Aura/Sources/Settings/SettingsView.swift`

**Interfaces:**
- Produces: `@Observable @MainActor final class DisplayNameStore { var name: String; func save() async }` — persists to `UserDefaults` (immediate crew name) AND calls `backend`/`upsert_display_name` via the sign-in path; `DisplayNameEditor` is the SwiftUI field (validates live via `DisplayName`); a Settings row edits it. Consumed by `GroupRideSession`'s `displayNameProvider: { store.name }` and the `.needsDisplayName` prompt (Task 16).

- [ ] **Step 1** Implement `DisplayNameStore` reading/writing `UserDefaults` key `crewDisplayName`, seeded from the Apple credential name captured at sign-in (see `AppleSignInController.Result.fullName`); `save()` normalizes via `DisplayName.normalized` and calls the backend's display-name upsert (reuse the existing `signIn(displayName:)` path or a dedicated call — check how the app currently persists it after `AppleSignInController`).
- [ ] **Step 2** `DisplayNameEditor` — a `TextField` bound to the store, showing a live "40 max" hint and disabling save when `DisplayName.normalized(text) == nil`. Use `AuraTheme` roles.
- [ ] **Step 3** Add a "Crew name" row to `SettingsView` presenting the editor.
- [ ] **Step 4** Preview + build-verify (builder agent). Manually confirm the editor rejects blank and caps length.
- [ ] **Step 5** Commit `feat(app): editable crew display name (store + editor + settings) (SP3)`.

---

## Task 13: `GroupRideMapOverlay` — peer dots (ViewAnnotation) + route ribbon

**Files:**
- Create: `Aura/Sources/GroupRide/GroupRideMapOverlay.swift`
- Modify: `Aura/Sources/Ride/RideMapView.swift` (accept optional `peers` + `nameMap` + `selfProgress`)

**Interfaces:**
- Consumes: `[RidePeer]`, `nameMap`, `PeerBearing`, `AuraTheme` status colours, the shared `Route.geometry`.
- Produces: `MapViewAnnotation`-based peer discs (colour by `PeerStatus` → white/lime/`AuraTheme.warning`/grey), a heading cone from `PeerBearing.heading(from:previousCoordinate, to:coordinate)`, a live pulse (respect `accessibilityReduceMotion`), sparse name tags, and the lit/dimmed route ribbon split at self's `progressMeters` (two `PolylineAnnotation`s or a line-gradient).

- [ ] **Step 1** Extend `RideMapView` to take `peers: [RidePeer] = []`, `nameMap: [UUID:String] = [:]`, `selfProgress: Double = 0`, and inside the `Map { }` content builder add, for each peer with a `coordinate`, a `MapViewAnnotation(coordinate:) { PeerDotView(...) }`. Keep the existing solo path (empty peers) unchanged.
- [ ] **Step 2** `PeerDotView` (in `GroupRideMapOverlay.swift`): the disc + initial + cone (`rotationEffect` by bearing) + pulse (`.opacity`/`.scale` repeating animation, gated on `!reduceMotion`, else a static ring). Colour from a `status → Color` map using `AuraTheme.accent`/`.warning`/etc.
- [ ] **Step 3a (TDD, pure): `RouteSplit` helper in AuraCore.** Create `AuraCore/Sources/AuraCore/GroupRide/RouteSplit.swift` + test. `enum RouteSplit { static func splitIndex(geometry: [Coordinate], atMeters: Double) -> Int }` — walk cumulative great-circle distance over `geometry`, return the index where cumulative distance first reaches `atMeters` (clamped to `0...geometry.count`). Tests: empty/1-point geometry → 0; `atMeters <= 0` → 0; `atMeters` beyond total → `geometry.count`; a mid-route value → the expected index on a known 3-point line. Write test → fail → implement → pass → commit before touching the view.
- [ ] **Step 3b** Route ribbon: use `RouteSplit.splitIndex(geometry:atMeters: selfProgress)` to draw the "behind" polyline dimmed (`AuraTheme.routeLine.opacity(0.25)`) and the "ahead" polyline bright, as two `PolylineAnnotation`s in the `Map { }` content.
- [ ] **Step 4** Build + **simulator screenshot** (builder/ios-build-verify): confirm dots render, colours match, pulse animates, tags aren't cluttered. Device-verify note carried to Task 18.
- [ ] **Step 5** Commit `feat(app): GroupRideMapOverlay peer dots + heading cone + route ribbon (SP3)`.

---

## Task 14: `GroupRosterSheet` (collapsed + expanded detents)

**Files:**
- Create: `Aura/Sources/GroupRide/GroupRosterSheet.swift`

**Interfaces:**
- Consumes: `GroupRosterViewData.rows(...)`, `AuraTheme`, the collapsed summary counts.
- Produces: a `.presentationDetents([.height(96), .large])`-style bottom sheet (or a custom draggable container over the map) rendering `RosterRow`s: avatar (initial in status colour), name, status pill (amber for stopped), `distanceLabel`, a route-position micro-bar. Collapsed handle: avatar stack + "N riding · M stopped" + spread bar. Empty (solo): "Waiting for your crew…" + code/share.

- [ ] **Step 1** Build `RosterRowView` (avatar + name + `distanceLabel` + status pill) from a `RosterRow`; Saira for numerals, SF Rounded for names.
- [ ] **Step 2** Collapsed summary view (counts derived from rows) + expanded `List`/`VStack`.
- [ ] **Step 3** Empty state ("Waiting for your crew…").
- [ ] **Step 4** Previews for: 4 mixed-status riders, solo-empty, one dropped. Build-verify + screenshot.
- [ ] **Step 5** Commit `feat(app): GroupRosterSheet collapsed/expanded roster (SP3)`.

---

## Task 15: `GroupToastHost` (membership toasts)

**Files:**
- Create: `Aura/Sources/GroupRide/GroupToastHost.swift`

**Interfaces:**
- Consumes: `session.toasts: [GroupToastEvent]` (append-only); drains/auto-dismisses.
- Produces: a top-anchored overlay that shows the newest toast, auto-dismisses after ~2.5 s, animates slide+fade (respect reduce-motion → fade only). Copy: `.joined(n)` → "\(n) joined", `.left(n)` → "\(n) left", `.hostEnded` → "The host ended the group ride".

- [ ] **Step 1** A `@State` cursor over the `toasts` array; on change, present the tail item; timer-dismiss.
- [ ] **Step 2** Toast chip styled with `AuraTheme.surface`/`mapScrim` + hairline.
- [ ] **Step 3** Previews (joined/left/ended). Build-verify.
- [ ] **Step 4** Commit `feat(app): GroupToastHost membership toasts (SP3)`.

---

## Task 16: `GroupRideFlowView` + create action + lobby + share link + navigation destination

**Files:**
- Create: `Aura/Sources/GroupRide/GroupRideFlowView.swift`, `GroupLobbyView.swift`
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift` (create action)
- Modify: `Aura/Sources/App/AuraApp.swift` / RootView (`.groupRide` destination)

**Interfaces:**
- Consumes: `AppRoute.groupRide(GroupRideEntry)`, `GroupRideSession`, `DisplayNameStore`, `GroupNavigateContainer` (Task 17).
- Produces: `GroupRideFlowView(entry:)` owns `@State session`, on appear calls `create`/`join` (gated), and switches on `session.phase`: `.needsDisplayName` → name prompt (reuses `DisplayNameEditor`) → retry; `.lobby` → `GroupLobbyView`; `.riding` → `GroupNavigateContainer`; `.createFailed` → a dismiss-with-message "This route is too detailed to share as a group ride." (§7); `.routeUnavailable` → "Couldn't load this ride's route." + dismiss; `.ended` → dismiss. `GroupLobbyView` shows the code, a Share button (`ShareLink(item: URL(string: "aura://join?code=\(code.rawValue)")!)`), the live roster (from `session`), and "Start riding" (`session.startRiding()`).

- [ ] **Step 1** `GroupRideFlowView` phase switch + `.needsDisplayName` handling (present editor, then re-invoke create/join).
- [ ] **Step 2** `GroupLobbyView` (code, ShareLink deep link, roster fills from `session.peers`+`nameMap`, Start).
- [ ] **Step 3** Add the create action to `RoutePreviewView` — a secondary "Ride together" button next to "Start RIDE": `router.push(.groupRide(.create(selected)))` (guard `selected != nil`).
- [ ] **Step 4** Register the destination: in the `.navigationDestination(for: AppRoute.self)` switch, add `case let .groupRide(entry): GroupRideFlowView(entry: entry)`.
- [ ] **Step 5** Build + simulator: plan a route → "Ride together" → lobby shows a code + Start. Commit `feat(app): group-ride flow + lobby + create action + share link (SP3)`.

---

## Task 17: `GroupRideJoinView` + deep-link routing + `GroupNavigateContainer`

**Files:**
- Create: `Aura/Sources/GroupRide/GroupRideJoinView.swift`, `GroupNavigateContainer.swift`
- Modify: `Aura/Sources/Plan/PlanView.swift` (join entry), `Aura/Sources/App/AppRouter.swift` (deep-link arm)

**Interfaces:**
- Consumes: `JoinCode`, `AppRoute.groupRide(.join(code))`, `DeepLink.join`, `GroupRideSession`, the overlay/sheet/toast.
- Produces: `GroupRideJoinView` (segmented 8-char input validating via `JoinCode`); a "Join a ride" entry on `PlanView` presenting it; `AppRouter.handle` arm for `.join(code)`: `guard !isRideActive` then `selectedTab = .ride; path = [.groupRide(.join(code))]`; `GroupNavigateContainer` = `NavigateHUDView(route:destination:)` + `GroupRideMapOverlay` overlay + `GroupRosterSheet` + `GroupToastHost` + a **"Reconnecting…" pill** (shown when `session.isLive == false`), reading one `GroupRideSession`.
- **Error copy (§7, D13):** two distinct messages, not one. A transport/network error (`URLError`) → "Couldn't reach the ride — try again." A `GroupRideError.joinFailed` (wrong code / full / ended / rate-limited — the RPC's deliberately generic failure) → "Couldn't join — double-check the code with your host." D13 only collapses the *RPC reasons* into one message; it does not merge network errors into it.

- [ ] **Step 1** `AppRouter.handle`: add
```swift
case let .join(code):
    selectedTab = .ride
    path = [.groupRide(.join(code))]
```
(the existing `guard !isRideActive` already blocks joining mid-ride). Add a unit test in `AuraKitTests`/app tests if `AppRouter` is testable, asserting the path after `handle(url: aura://join?code=…)`.
- [ ] **Step 2** `GroupRideJoinView` — segmented input, paste, `JoinCode` validation, `router.push(.groupRide(.join(code)))` on submit; single inline error string for a failed join (the failure surfaces from `GroupRideFlowView`'s `join`, shown via `session.phase`/an error field).
- [ ] **Step 3** Add "Join a ride" to `PlanView` (a button opening `GroupRideJoinView`).
- [ ] **Step 4** `GroupNavigateContainer` composes the existing `NavigateHUDView(route:destination:)` with the overlay + roster sheet + toast host bound to `session`. It shows the group chrome (overlay/sheet/toast) **only while `session.phase == .riding`**; when `phase == .ended` (host ended, D9) it hides all group chrome but keeps `NavigateHUDView` running so the rider continues solo. It renders a small "Reconnecting…" pill near the sheet whenever `session.isLive == false`.
- [ ] **Step 5** Previews: `.riding` (crew chrome visible), `.ended` (chrome gone, solo HUD persists), `isLive == false` (pill shown). Build-verify each. (End-to-end two-identity happy path is Task 18.) Commit `feat(app): join-by-code + deep-link routing + group navigate container + reconnect pill (SP3)`.

---

## Task 18: Integration — lint, build, simulator smoke, whole-branch review

**Files:** none new (verification + fixes).

- [ ] **Step 1** `swiftlint --strict` over the **whole repo including tests** (SP2 lesson): `swiftlint --strict` from repo root. Fix any `large_tuple`/complexity/body-length hits (extract helpers as SP2 did). Expected: 0 violations.
- [ ] **Step 2** Full package tests: `swift test --package-path AuraCore` — all green.
- [ ] **Step 3** App build (builder agent) — SUCCESS.
- [ ] **Step 4** Simulator smoke with two identities (create on one, join on the other via the code): confirm both see named dots, correct ahead/behind, stopped→amber, a member leaving toasts + drops the dot, host End dissolves the crew layer while solo nav continues. Use the ios-build-verify / simulator tooling; capture screenshots. **Record device-verify follow-ups** (Mapbox `ViewAnnotation` perf with 8 dots + pulse; reconnect path from SP2) in memory.
- [ ] **Step 5** Whole-branch review: run this skill's `scripts/review-package $(git merge-base main HEAD) HEAD`, dispatch the final code-reviewer (most-capable model) with the SP3 spec's Global Constraints. Fix Critical/Important findings with ONE fix subagent. Then hand off to `finishing-a-development-branch`.

---

## Self-review notes (author)

- **Spec coverage:** every §5 component maps to a task (PeerBearing→T3, PeerDistance→T4, DisplayName→T5, GroupRosterViewData→T6, GroupRideSession→T9/T10a/T10b, backend ext→T8, ride_roster→T1, live conformer→T11, DisplayNameStore→T12, overlay+RouteSplit→T13, roster sheet→T14, toasts→T15, lobby/create/flow→T16, join/deep-link/container→T17). Amber token (D6)→T2. Deep-link (D7)→T7. Gate (D8)→T5+T9(both create+join)+T12. Host-End-only (D12)→T10a/T16/T17. Generic join error (D13)→T17. §7 states: create-too-large→T8/T9/T11/T16; route-unavailable→T9/T16; reconnect pill→T17; waiting-for-crew→T14; peer-not-yet-named→T6/T10b.
- **No route-vend migration** (spec §4.3) — confirmed: `create_ride`/`join_ride` already `return public.rides` incl. `route jsonb`; only the Swift decoder changes (T11).
- **Type consistency:** `JoinedRide{ride,route:Data}`, `RosterMember{userID,displayName,role: RideMember.Role}`, `GroupRideEntry{.create(Route),.join(JoinCode)}`, `RosterRow`, `GroupToastEvent`, `GroupRideSession.Phase{idle,lobby,riding,ended,routeUnavailable,createFailed,needsDisplayName}` used identically across tasks. Pure helpers take `isImperial: Bool` (not `DistanceUnits`, which lives in AuraKit).

### Plan revisions after the 2-reviewer adversarial pass

- **Compile fixes:** `Units`→`isImperial: Bool` (T4/T6 — `DistanceUnits` is in AuraKit, unreachable from AuraCore); `RosterMember.role: RideMember.Role` (no `GroupRide.Role`); T8 test file is **Modify** not Create (existing `joined.id`→`joined.ride.id`); T1 pgTAP captures `join_code` under host claims before switching (RLS hides it pre-membership); `currentLifecycle: RideLifecycle` declared in T10a; `JoinedRide` has no `selfUserID` (T9 uses `backend.currentUserID()`). Verified accurate by the reviewer: `Route` init/Codable, `RidePeer` init, `RideSession` API, transport events, MapboxMaps v11 `MapViewAnnotation`, `client.auth.session.user.id`, SQL return shapes, `JoinCode`/`Route` not `Hashable` (manual `GroupRideEntry: Hashable` required).
- **Coverage fixes:** added the >256 KB **create-failure** path (`GroupRideError.routeTooLarge` + `Phase.createFailed`, T8/T9/T11/T16); the **route-decode-failure→auto-leave** test (T9); the **name-refresh convergence** and **D11 no-toast-on-motion** tests with real bodies (T10b); the **join-side gate** test (T9); the **"Reconnecting…" pill** + **host-end dissolve** build steps + previews (T17); `RouteSplit` committed as a tested pure helper (T13); **distinct network vs join error copy** (T17). Task 10 split into **10a** (tick/snapshot/reconnect/end) and **10b** (toasts/nameMap) so each is one reviewer gate with real tests.
```
