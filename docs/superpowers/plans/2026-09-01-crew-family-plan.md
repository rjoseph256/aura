# Crew Family (ROH-225) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the group-ride lobby actually fill, give riders stable identity hues on map + lobby, and turn the join/waiting/failure flows into honest, recoverable surfaces.

**Architecture:** Pure seams in AuraCore/AuraKit (roster merge, lobby poll cadence, failure classifier, color latch, paste parser, count label) drive thin SwiftUI adoption in the app target. The session (`GroupRideSession`) stays the single owner of live state; surfaces look up, never recompute.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`@Test`/`#expect`), SwiftPM package `AuraCore` (two targets: AuraCore pure, AuraKit session layer), xcodegen-generated app project, Supabase backend (NO server changes in this slice).

**Spec:** `docs/superpowers/specs/2026-08-31-crew-family-design.md` (v2, PO-approved 2026-09-01 with decisions 1a/2a/3a). Visual reference: `docs/superpowers/specs/2026-08-31-crew-identity-board.svg` (approved gate-1 identity board — the implementation reference for CrewMonogram, JoinCodeText, You/Host markers, and the join-screen layout).

**Board:** ROH-227 (A0, Tasks 1–2) · ROH-231 (D, Tasks 3–8) · ROH-229 (B, Tasks 9–10) · ROH-230 (C, Tasks 11–12) · ROH-228 (A, Tasks 13–19) · Task 20 closes the slice. Move each issue Todo → In Progress → In Review → Done as its tasks run; watch for Linear auto-completing issues from PR references and revert if wrong.

## Global Constraints

- **No new motion anywhere.** The only animation that may fire is the lobby's existing `.easeOut(duration: 0.22)` on `rows.count` (`GroupLobbyView.swift:81`).
- **No Theme-wide changes**: no CTAButtonStyle edits, no `.mapCard`, no gradients, no pulsing (charter).
- **Sentence case** for all new/changed copy; no uppercase tracked eyebrows in the group module. Exception: the roster's existing "YOU" marker style stays (it is a marker, not an eyebrow — spec §4).
- **`GroupRideSession.Phase` stays payload-free.** Failure reason is a property *alongside* phase, cleared at the top of every attempt, written adjacent to the phase with no suspension between (spec §7).
- **The ROH-81 single structural branch in `GroupRideFlowView.content` is untouched.**
- **Navigation is single-write**: `replaceTop`-style path mutations only; no `dismiss()` + push; no new NavigationStack.
- **No server changes.** The join oracle stays generic (ROH-226); failure split is client-only.
- **Async closures are NEVER default arguments** (ROH-110); nil-default + init-body construction, as `GroupRideSession.sleep` documents.
- Previews used as PO/gate evidence use **frozen UUIDs** (`UUID(uuidString:)!`), never fresh `UUID()`.
- **SwiftLint runs from the repo root** (`swiftlint --strict`); `swift test` runs in `AuraCore/` and prints **two totals — both must be green**.
- **`cd Aura && xcodegen`** after every app-target file add/remove (the `.xcodeproj` is gitignored).
- Delegate app builds to the `apple-platform-build-tools` builder agent; implementers write app-target SwiftUI directly (no write-capable agent type lacks the Agent tool — grandchild risk).
- **Verification tiers:** Tier 1 (sim, this plan's steps) for all visuals; **Tier 2 two-phone, queued** for A0 lobby fill + per-device hue stability (Task 20 files the Verification issue). A0 is the slice's merge-worthiness bar.
- **File boundary:** the identity-carriers branch edits `NavigateHUDView.swift` and holds `GroupRideMapOverlay.swift`. Tasks 17–19 run a rebase check first (Task 17 step 1). This slice owns `PeerAnnotations.swift` and the five Crew files.
- **PO gate:** whole-slice before/after set before merge (Task 20). The identity-board gate already passed; do not re-open settled design decisions (white = me; roster keeps status colors; explicit Join + caption; roster poll).

Line numbers cite HEAD at plan time (`d5228d4` + docs commits) — locate by symbol if drifted.

---

### Task 1: Roster merge seam (`LivePresenceState.merge` + `RideSession.mergeRoster`)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/GroupRide/LivePresenceState.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/RideSession.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/LivePresenceStateTests.swift` (extend)

**Interfaces:**
- Consumes: existing `LivePresenceState.apply/remove/peers`, `RidePeer`.
- Produces: `LivePresenceState.merge(roster: [RidePeer])` (mutating, idempotent, never touches known peers) and `RideSession.mergeRoster(_ members: [RidePeer])` — Task 2's poll calls the latter.

- [ ] **Step 1: Write the failing tests** (append to `LivePresenceStateTests.swift`)

```swift
@Test func mergeAddsUnknownMembersAsGiven() {
    var state = LivePresenceState(roster: [], droppedTimeout: 15)
    let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    state.merge(roster: [RidePeer(userID: id, displayName: "Priya", status: .awaiting)])
    #expect(state.peers.map(\.userID) == [id])
    #expect(state.peers[0].status == .awaiting)
}

@Test func mergeNeverOverwritesAKnownPeer() {
    let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
    var state = LivePresenceState(roster: [], droppedTimeout: 15)
    let fix = Date()
    state.apply(LivePositionPayload(userID: id, coordinate: Coordinate(latitude: 1, longitude: 2),
                                    progressMeters: 100, recordedAt: fix, motionState: .moving), now: fix)
    state.merge(roster: [RidePeer(userID: id, displayName: "Priya", status: .awaiting)])
    #expect(state.peers[0].status == .riding, "a lobby roster poll must not reset a live peer")
    #expect(state.peers[0].coordinate != nil)
}

@Test func mergeIsIdempotent() {
    let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
    var state = LivePresenceState(roster: [], droppedTimeout: 15)
    let member = RidePeer(userID: id, displayName: "Priya", status: .awaiting)
    state.merge(roster: [member])
    state.merge(roster: [member])
    #expect(state.peers.count == 1)
}
```

- [ ] **Step 2: Run to verify they fail** — `cd AuraCore && swift test --filter LivePresenceStateTests` → FAIL: `merge` not defined.

- [ ] **Step 3: Implement.** In `LivePresenceState` (after `remove(userID:)`):

```swift
/// Adds roster entries for members the presence layer hasn't seen yet, leaving every known
/// peer untouched — a lobby roster poll must never reset a live peer's position or status
/// (ROH-227). Idempotent.
public mutating func merge(roster: [RidePeer]) {
    for member in roster where byID[member.userID] == nil {
        byID[member.userID] = member
    }
}
```

In `RideSession` (after `startManaged(roster:)`):

```swift
/// The lobby poll's merge seam (ROH-227): newly-joined members appear in presence with
/// status `.awaiting`, exactly as the seed roster would have carried them.
public func mergeRoster(_ members: [RidePeer]) {
    presence.merge(roster: members)
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter LivePresenceStateTests`; then the full suite (`swift test`, both totals green).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(roh-227): roster merge seam — presence learns joined members without a position"`

---

### Task 2: Lobby roster poll in `GroupRideSession`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` (add `rosterCallCount` spy)
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideLobbyPollTests.swift`

**Interfaces:**
- Consumes: Task 1's `RideSession.mergeRoster(_:)`; the injected `sleep` closure (the session's existing clock seam); `refreshRoster()`.
- Produces: while `phase == .lobby`, `peers` gains joined members within one `lobbyPollInterval` (default 4 s) without any `.position`. New init param `lobbyPollInterval: Duration = .seconds(4)` (defaulted — no call-site changes).

Mechanism: `beginLiveSession()` starts a poll task when the phase is `.lobby`. The loop sleeps on the injected `sleep`, re-checks the phase, calls the existing coalesced `refreshRoster()`, and merges the members into presence. It self-terminates on any phase exit and is cancelled in `teardownLive`. Idempotent with `beginLiveSession()`'s seed because `merge` skips known IDs. The existing `.position`-triggered refresh stays.

- [ ] **Step 1: Add the spy.** In `InMemoryGroupRideBackend`'s `Store` (next to `endLeaveCallCount`): `var rosterCallCount = 0   // test spy: how many times roster() ran`. In `roster(rideID:)`, increment it first. Tests read it as `backend.store.rosterCallCount` (the file's existing spy idiom — see `GroupRideEndTimeoutTests`).

- [ ] **Step 2: Write the failing tests** (new file):

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Releases the session's injected `sleep` one interval at a time, so the lobby poll's
/// cadence is test-driven rather than wall-clock (the end/leave timeout precedent).
///
/// CANCELLATION-AWARE ON PURPOSE: the same injected `sleep` also feeds `withTimeout`'s
/// timer leg (end/leave today, the entry timeout after Task 4). `withTimeout` awaits its
/// cancelled timer child on the way out, so a gate that ignored cancellation would
/// deadlock every `create`/`join`/`end` in these tests once Task 4 lands.
actor SleepGate {
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    nextID += 1
                    waiters[nextID] = continuation
                }
            }
        } onCancel: {
            Task { await self.release() }
        }
    }

    func release() {
        let parked = waiters
        waiters = [:]
        for continuation in parked.values { continuation.resume() }
    }
}

@MainActor
struct GroupRideLobbyPollTests {
    /// Bounded, condition-driven settle (ROH-217 precedent) — never a wall-clock sleep.
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    func makeHost(gate: SleepGate) async -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "host", nonce: "n", displayName: "Jamie")
        let session = GroupRideSession(
            backend: backend, transport: InMemoryRideSessionTransport(),
            displayNameProvider: { "Jamie" },
            sleep: { _ in await gate.wait() })
        await session.create(route: nil)
        return (session, backend)
    }

    @Test func aJoinerAppearsAfterOnePollIntervalWithNoPosition() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        await session.beginLiveSession()
        // A second identity joins AFTER the seed — the exact case the lobby never surfaced.
        let guest = InMemoryGroupRideBackend(sharing: backend)
        try await guest.signIn(idToken: "guest", nonce: "n", displayName: "Priya")
        _ = try await guest.joinRide(code: session.joinCode!)
        #expect(session.peers.count == 1, "not yet — no interval has elapsed")
        await gate.release()
        await settle { session.peers.count == 2 }
        #expect(session.peers.count == 2)
        #expect(session.peers.contains { $0.status == .awaiting && session.nameMap[$0.userID] == "Priya" })
    }

    @Test func thePollIsIdempotentWithTheSeedRoster() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        let guest = InMemoryGroupRideBackend(sharing: backend)
        try await guest.signIn(idToken: "guest", nonce: "n", displayName: "Priya")
        _ = try await guest.joinRide(code: session.joinCode!)
        await session.beginLiveSession()   // seed already contains Priya
        let seeded = session.peers.count
        await gate.release()
        await settle { false }             // give the poll a full settle window
        #expect(session.peers.count == seeded, "re-polling the same roster adds nothing")
    }

    @Test func thePollStopsWhenTheLobbyIsLeft() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        await session.beginLiveSession()
        await session.end()                // teardownLive cancels the poll
        let calls = backend.store.rosterCallCount
        await gate.release()               // wakes any straggler — its phase guard must hold
        await settle { false }
        #expect(backend.store.rosterCallCount == calls, "no roster fetch after teardown")
    }
}
```

(`end()` itself runs a `withTimeout` whose timer parks on the gate and is released by cancellation — that is the SleepGate's cancellation-awareness earning its keep.)

- [ ] **Step 3: Run to verify fail** — `swift test --filter GroupRideLobbyPollTests` → FAIL (no poll exists; first test's count stays 1).

- [ ] **Step 4: Implement.** In `GroupRideSession`:

Stored state + init (all defaulted; keep `sleep` last, nil-defaulted per ROH-110):

```swift
/// How often the lobby re-reads the roster so joiners appear pre-ride (ROH-227, decision 1a).
private let lobbyPollInterval: Duration
private var lobbyPollTask: Task<Void, Never>?
```

```swift
public init(backend: any GroupRideBackend, transport: any RideSessionTransport,
            displayNameProvider: @escaping @Sendable () -> String, cadence: LiveShareCadence = .init(),
            endTimeout: Duration = .seconds(4),
            lobbyPollInterval: Duration = .seconds(4),
            sleep: (@Sendable (Duration) async throws -> Void)? = nil) {
    // …existing assignments…
    self.lobbyPollInterval = lobbyPollInterval
```

At the end of `beginLiveSession()` (after `peers = session.peers`):

```swift
if phase == .lobby { startLobbyPoll() }
```

New members (private, near `startTicker`):

```swift
/// Re-reads the roster on a cadence while the rider waits in the lobby, so a joining friend
/// appears without a `.position` (which never flows pre-ride — ROH-227). Self-terminating on
/// any phase exit; cancelled in `teardownLive`; idempotent with `beginLiveSession()`'s seed
/// because `mergeRoster` skips known members.
private func startLobbyPoll() {
    lobbyPollTask?.cancel()
    lobbyPollTask = Task { [weak self] in
        while !Task.isCancelled {
            guard let self, self.phase == .lobby else { return }
            try? await self.sleep(self.lobbyPollInterval)
            guard !Task.isCancelled, self.phase == .lobby else { return }
            let members = await self.refreshRoster()
            self.mergeLobbyRoster(members)
        }
    }
}

private func mergeLobbyRoster(_ members: [RosterMember]) {
    guard phase == .lobby, let session = rideSession, !members.isEmpty else { return }
    session.mergeRoster(members.map {
        RidePeer(userID: $0.userID, displayName: $0.displayName, status: .awaiting)
    })
    peers = session.peers
}
```

In `teardownLive(_:)` (with the other cancellations): `lobbyPollTask?.cancel(); lobbyPollTask = nil`.

- [ ] **Step 5: Run to verify pass** — the three new tests, then the full suite (both totals). If `aJoinerAppears…` flakes, the bug is real ordering, not the test: `refreshRoster`'s coalescing guard returns `[]` to a second concurrent caller — make sure the poll's merge uses the *returned* members, not `nameMap`.

- [ ] **Step 6: Commit** — `git commit -am "feat(roh-227): lobby roster poll — the room fills without a position"`

---

### Task 3: Entry-failure taxonomy (`connectionFailed` + classifier + spies)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift` (add enum case)
- Create: `AuraCore/Sources/AuraKit/GroupRide/EntryFailure.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` (spies)
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/EntryFailureTests.swift`

**Interfaces:**
- Produces: `GroupRideError.connectionFailed`; `EntryFailureReason { connectionFailed, rejected }`; `EntryFailure.isConnectionFailure(_:) -> Bool`; InMemory spies `forceJoinError: GroupRideError?`, `hangJoin: Bool`, `hangCreate: Bool` (parking until cancelled, mirroring `hangEndLeave`). Tasks 4–5 consume all of these.

- [ ] **Step 1: Write the failing tests:**

```swift
import Testing
import Foundation
@testable import AuraKit

struct EntryFailureTests {
    struct SomeError: Error {}

    @Test func timeoutReadsAsConnectionFailure() {
        #expect(EntryFailure.isConnectionFailure(TimeoutError()))
    }
    @Test func typedConnectionFailureReadsAsConnectionFailure() {
        #expect(EntryFailure.isConnectionFailure(GroupRideError.connectionFailed))
    }
    @Test func urlErrorReadsAsConnectionFailure() {
        #expect(EntryFailure.isConnectionFailure(URLError(.notConnectedToInternet)))
    }
    @Test func aServerRejectionIsNotAConnectionFailure() {
        #expect(!EntryFailure.isConnectionFailure(GroupRideError.joinFailed))
    }
    @Test func anUnknownErrorDefaultsToRejected() {
        #expect(!EntryFailure.isConnectionFailure(SomeError()))
    }
}
```

- [ ] **Step 2: Verify fail** (type not defined), then implement.

`GroupRideError` gains one case with the comment pattern the enum already uses:

```swift
case connectionFailed // transport reachability: the server was never reached (ROH-231)
```

New file `EntryFailure.swift`:

```swift
import Foundation

/// Which way a create/join attempt failed. Carried by `GroupRideSession` ALONGSIDE its
/// payload-free `Phase` — an associated value would break `phase ==` and the ROH-81
/// single-branch `if`. Client-detectable causes only; the server's join answer stays a
/// deliberately generic oracle (ROH-226), so `.rejected` never guesses at a cause.
public enum EntryFailureReason: Equatable, Sendable {
    case connectionFailed
    case rejected
}

public enum EntryFailure {
    /// True when the error means the server was never reached (or never answered in time),
    /// as opposed to answering and saying no.
    public static func isConnectionFailure(_ error: any Error) -> Bool {
        if error is TimeoutError { return true }
        if (error as? GroupRideError) == .connectionFailed { return true }
        if error is URLError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain
    }
}
```

InMemory spies (Store, same comment style as the existing block): `var forceJoinError: GroupRideError?   // test spy`, `var hangJoin = false   // test spy: park joinRide until cancelled`, `var hangCreate = false   // test spy: park createRide until cancelled`. In `joinRide`, before the normal logic: `if store.hangJoin { try await Task.sleep(for: .seconds(1000)) }` then `if let forced = store.forceJoinError { throw forced }` — the exact `hangEndLeave` mechanism (`InMemoryGroupRideBackend.swift:108`): `Task.sleep` throws `CancellationError` when `withTimeout` cancels the parked operation, which the timeout maps to `TimeoutError`, which the classifier reads as a connection failure. Same `hangCreate` line at the top of `createRide`. Tests drive them via `backend.store.<spy> = …` directly.

- [ ] **Step 3: Run the new tests to green, then the full suite** (the new enum case may break exhaustive switches — fix any the compiler flags; `swift build` in AuraCore first is the fastest signal).

- [ ] **Step 4: Commit** — `git commit -am "feat(roh-231): entry-failure taxonomy — connection vs rejection, classifier + spies"`

---

### Task 4: Session carries the reason; attempts are bounded and re-enterable

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEntryFailureTests.swift`

**Interfaces:**
- Consumes: Task 3's `EntryFailureReason`/`EntryFailure`, `withTimeout(_:sleep:operation:)`, InMemory spies.
- Produces: `public private(set) var entryFailureReason: EntryFailureReason?`; `create`/`join` reset `entryFailureReason = nil` and `phase = .idle` at the top of every attempt (after the name guard), wrap their backend calls in `withTimeout(entryTimeout, sleep:)`, and on failure write reason then phase adjacently with no suspension between. New init param `entryTimeout: Duration = .seconds(10)` (defaulted, placed after `endTimeout`).

- [ ] **Step 1: Write the failing tests:**

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideEntryFailureTests {
    func makeSession(backend: InMemoryGroupRideBackend,
                     sleep: (@Sendable (Duration) async throws -> Void)? = nil) -> GroupRideSession {
        GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                         displayNameProvider: { "Jamie" }, sleep: sleep)
    }

    @Test func anUnknownCodeIsARejection() async {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        let session = makeSession(backend: backend)
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        #expect(session.entryFailureReason == .rejected)
    }

    @Test func aTransportFailureIsAConnectionFailure() async {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        backend.store.forceJoinError = .connectionFailed
        let session = makeSession(backend: backend)
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        #expect(session.entryFailureReason == .connectionFailed)
    }

    @Test func aHungJoinResolvesToAConnectionFailureNotAnEternalSpinner() async {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        backend.store.hangJoin = true
        // Instant sleep: the entry timeout elapses immediately; the parked join is cancelled.
        let session = makeSession(backend: backend, sleep: { _ in })
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        #expect(session.entryFailureReason == .connectionFailed)
    }

    @Test func aHungCreateResolvesToAConnectionFailure() async {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        backend.store.hangCreate = true
        let session = makeSession(backend: backend, sleep: { _ in })
        await session.create(route: nil)
        #expect(session.phase == .createFailed)
        #expect(session.entryFailureReason == .connectionFailed)
    }

    @Test func aRetryClearsTheReasonAndReEntersLoading() async {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        let session = makeSession(backend: backend)
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)   // fails: no such ride
        #expect(session.entryFailureReason == .rejected)
        await session.create(route: nil)                            // a fresh attempt succeeds
        #expect(session.entryFailureReason == nil, "cleared at the top of the attempt")
        #expect(session.phase == .lobby)
    }
}
```

(The hang tests only terminate because `withTimeout` cancels the parked operation and the spy's continuation resumes on cancellation — that is why Task 3 copies `hangEndLeave`'s mechanism exactly.)

- [ ] **Step 2: Verify fail**, then implement. Init gains (after `endTimeout`): `entryTimeout: Duration = .seconds(10),` and stores `private let entryTimeout: Duration`. Stored property near `startFailed`:

```swift
/// Why the most recent create/join attempt failed — ALONGSIDE the payload-free phase
/// (see `EntryFailureReason`). Cleared at the top of every attempt; written immediately
/// before the failure phase with no suspension between, so no observer can see a fresh
/// failure phase with a stale reason.
public private(set) var entryFailureReason: EntryFailureReason?
```

`create(route:)` becomes:

```swift
public func create(route inputRoute: Route?) async {
    guard DisplayName.normalized(displayNameProvider()) != nil else {
        phase = .needsDisplayName
        return
    }
    entryFailureReason = nil
    phase = .idle   // a retry re-enters the loading surface
    do {
        let resolvedSelfUserID = try await withTimeout(entryTimeout, sleep: sleep) { [backend] in
            try await backend.currentUserID()
        }
        let routeData = try inputRoute.map { try JSONEncoder().encode($0) }
        let ride = try await withTimeout(entryTimeout, sleep: sleep) { [backend] in
            try await backend.createRide(route: routeData)
        }
        // …existing success body unchanged (rideID/joinCode/…/phase = .lobby)…
    } catch {
        entryFailureReason = EntryFailure.isConnectionFailure(error) ? .connectionFailed : .rejected
        phase = .createFailed
    }
}
```

`join(code:)`'s failure block becomes (success body unchanged):

```swift
    entryFailureReason = nil
    phase = .idle
    let resolvedSelfUserID: UUID
    let joined: JoinedRide
    do {
        (resolvedSelfUserID, joined) = try await withTimeout(entryTimeout, sleep: sleep) { [backend] in
            let uid = try await backend.currentUserID()
            let ride = try await backend.joinRide(code: code)
            return (uid, ride)
        }
    } catch {
        entryFailureReason = EntryFailure.isConnectionFailure(error) ? .connectionFailed : .rejected
        phase = .joinFailed
        return
    }
```

- [ ] **Step 3: Run the new tests, then the FULL suite.** Existing lifecycle tests assert phase sequences around create/join — if any observed the transient `.idle`, read the failure before "fixing" either side; the reset-at-top is spec-mandated.

- [ ] **Step 4: Commit** — `git commit -am "feat(roh-231): session entry attempts — reason alongside phase, bounded by the injected clock"`

---

### Task 5: Live backend maps reachability failures (app target)

**Files:**
- Modify: `Aura/Sources/Sync/SupabaseGroupRideBackend.swift`

**Interfaces:**
- Consumes: Task 3's `EntryFailure.isConnectionFailure`, `GroupRideError.connectionFailed`.
- Produces: `joinRide` and `createRide` throw `.connectionFailed` for reachability errors instead of collapsing them; server answers still collapse to `.joinFailed` (join) or propagate (create).

- [ ] **Step 1: Edit `joinRide`'s catch** (`SupabaseGroupRideBackend.swift:56`) from `catch { throw GroupRideError.joinFailed }` to:

```swift
        } catch let error where EntryFailure.isConnectionFailure(error) {
            // One bar of signal is not a wrong code: reachability failures surface as
            // connection trouble, everything the server actually answered stays the
            // deliberately generic rejection (ROH-226).
            throw GroupRideError.connectionFailed
        } catch { throw GroupRideError.joinFailed }
```

- [ ] **Step 2: Edit `createRide`** — after the existing `routeTooLarge` catch, add:

```swift
        } catch let error as PostgrestError { throw error
        } catch let error where EntryFailure.isConnectionFailure(error) {
            throw GroupRideError.connectionFailed
        }
```

Keep the `routeTooLarge` mapping first and untouched. (The `PostgrestError` re-throw keeps server answers classified as `.rejected` by the session even if their NSError bridging carries a URL domain — the classifier must only see genuine transport errors here.)

- [ ] **Step 3: Verify it compiles** — dispatch the builder agent: build the Aura app scheme for simulator. The classification logic itself is covered by Task 3's package tests (this target has no test bundle — cite that in the PR).

- [ ] **Step 4: Commit** — `git commit -am "feat(roh-231): live backend distinguishes reachability from rejection"`

---

### Task 6: `AppRoute.joinRide(seed:)` + `AppRouter.replaceTop(with:)`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`
- Modify: `Aura/Sources/App/AppRouter.swift`
- Modify: `Aura/Sources/AuraApp.swift:115` (destination), `Aura/Sources/Home/HomeView.swift:352` (call site)
- Test: `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift` (extend/fix)

**Interfaces:**
- Produces: `case joinRide(seed: String)` (seed participates in `==`/`hash`); `AppRouter.replaceTop(with: AppRoute)` — a single-write top replacement with no auth gate (the join screen needs none). Task 7's Try-again consumes both.

- [ ] **Step 1: Write the failing test** (append to `AppRouteTests.swift`):

```swift
@Test func joinRideSeedParticipatesInIdentity() {
    #expect(AppRoute.joinRide(seed: "AB3KQ9RT") == AppRoute.joinRide(seed: "AB3KQ9RT"))
    #expect(AppRoute.joinRide(seed: "AB3KQ9RT") != AppRoute.joinRide(seed: ""))
}
```

- [ ] **Step 2: Verify it fails to compile**, then implement. In `AppRoute`:

```swift
/// The group-ride join-code entry screen, pushed on the nav stack (not a sheet) so it
/// never conflicts with Home's always-present dashboard sheet. `seed` pre-fills the code
/// boxes — "" for a fresh entry, the typed code for a Try-again return (ROH-231).
case joinRide(seed: String)
```

`==`: `case let (.joinRide(a), .joinRide(b)): return a == b`. `hash`: `case let .joinRide(seed): hasher.combine(4); hasher.combine(seed)`. Fix every other `.joinRide` reference the compiler flags: `HomeView.swift:352` → `leaveHome(pushing: .joinRide(seed: ""))`; `AuraApp.swift:115` → `case let .joinRide(seed): GroupRideJoinView(seed: seed)` (keep the existing `.navigationBarBackButtonHidden(true)` and comment). Grep for stragglers: `grep -rn "\.joinRide" Aura/ AuraCore/ --include="*.swift"`.

In `AppRouter` (below `replaceTopWithGroupRide`):

```swift
/// Single-write top replacement for transient screens with no auth gate (the join screen).
/// Same rationale as `replaceTopWithGroupRide`: never dismiss() + push in one tick.
func replaceTop(with route: AppRoute) {
    if path.isEmpty { path = [route] } else { path[path.count - 1] = route }
}
```

- [ ] **Step 3: Run** `swift test --filter AppRouteTests`, then both totals; builder-build the app.

- [ ] **Step 4: Commit** — `git commit -am "feat(roh-231): joinRide carries a seed; router gains a plain replaceTop"`

---

### Task 7: Flow surfaces — entry-aware loading, honest failures, exits that work

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupRideFlowView.swift`

**Interfaces:**
- Consumes: `session.entryFailureReason` (Task 4), `router.replaceTop(with:)` + `.joinRide(seed:)` (Task 6), `invokeEntry()` (existing).
- Produces: the five `dismissMessage` sites gain `detail:`/retry support; `.idle` becomes an entry-aware loading surface. Copy is exact — do not paraphrase.

- [ ] **Step 1: Extend `dismissMessage`:**

```swift
private func dismissMessage(title: String, detail: String? = nil, systemImage: String,
                            retryTitle: String? = nil, retry: (() -> Void)? = nil) -> some View {
    VStack(spacing: AuraTheme.Spacing.lg) {
        Spacer()
        Image(systemName: systemImage)
            .font(.largeTitle)
            .foregroundStyle(AuraTheme.textSecondary)
        VStack(spacing: AuraTheme.Spacing.xs) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, AuraTheme.Spacing.xxl)
        Spacer()
        VStack(spacing: AuraTheme.Spacing.sm) {
            if let retryTitle, let retry {
                Button(retryTitle, action: retry).buttonStyle(.ctaPrimary)
                Button("Back") { router.pop() }.buttonStyle(.ctaTertiary)
            } else {
                Button("Back") { router.pop() }.buttonStyle(.ctaPrimary)
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
        .padding(.bottom, AuraTheme.Spacing.xxl)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AuraTheme.background.ignoresSafeArea())
}
```

(Title steps up to `textPrimary`+semibold now that a detail line exists beneath it; a retry-less surface keeps Back primary so `endedLobbySurface` is visually unchanged in structure.)

- [ ] **Step 2: Replace `.idle`** with an entry-aware loading surface:

```swift
case .idle:
    entryLoading
```

```swift
/// Entry-aware, bounded loading (ROH-231): the session's entryTimeout guarantees this
/// resolves — a hung create/join lands on the connection-failure surface, never here forever.
private var entryLoading: some View {
    VStack(spacing: AuraTheme.Spacing.lg) {
        Image(systemName: "person.2.fill")
            .font(.largeTitle)
            .foregroundStyle(AuraTheme.textSecondary)
        ProgressView()
        Text(entryIsJoin ? "Joining your crew…" : "Setting up your crew ride…")
            .font(.subheadline)
            .foregroundStyle(AuraTheme.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AuraTheme.background.ignoresSafeArea())
}

private var entryIsJoin: Bool {
    if case .join = entry { return true }
    return false
}
```

- [ ] **Step 3: Rewrite the failure cases** in `otherPhaseContent`:

```swift
case .createFailed:
    dismissMessage(
        title: connectionFailed ? "Couldn't reach the ride." : "Couldn't start your crew ride.",
        detail: connectionFailed ? "Check your connection and try again." : "Try again in a moment.",
        systemImage: connectionFailed ? "wifi.exclamationmark" : "person.2.slash",
        retryTitle: "Try again",
        retry: { Task { await invokeEntry() } }
    )

case .routeUnavailable:
    dismissMessage(
        title: "Couldn't load this ride's route.",
        detail: "Ask your host to check the ride, then try joining again.",
        systemImage: "exclamationmark.triangle"
    )

case .joinFailed:
    dismissMessage(
        title: connectionFailed ? "Couldn't reach the ride." : "Couldn't join that ride.",
        detail: connectionFailed ? "Check your connection and try again."
                                 : "Check the code with your host and try again.",
        systemImage: connectionFailed ? "wifi.exclamationmark" : "person.crop.circle.badge.xmark",
        retryTitle: "Try again",
        retry: {
            if case let .join(code) = entry {
                router.replaceTop(with: .joinRide(seed: code.rawValue))
            } else {
                Task { await invokeEntry() }
            }
        }
    )
```

with `private var connectionFailed: Bool { session.entryFailureReason == .connectionFailed }`. The corrupt-payload branch in `ridingContainer` gains the same `detail: "Ask your host to check the ride, then try joining again."`. `endedLobbySurface` is untouched (that ride is over; Back is the only honest exit). That is all five `dismissMessage` sites accounted for: createFailed, routeUnavailable, joinFailed, corrupt-payload, endedLobby.

- [ ] **Step 4: Builder-build; sim-verify Tier 1.** On the booted sim (`D221B3C5-13DE-482F-B0FD-017B305EC31B`): (a) type a wrong-but-well-formed code against the live backend → rejected surface, exact copy, Try again returns to the join screen with the code still in the boxes; (b) toggle sim network off (Settings → Wi‑Fi in the sim, or macOS network off) and join → connection surface; (c) create → loading shows "Setting up your crew ride…". Screenshot each.

- [ ] **Step 5: Commit** — `git commit -am "feat(roh-231): flow surfaces — entry-aware loading, honest failure copy, Try again exits"`

---

### Task 8: Name-prompt framing (`DisplayNameEditor.contextLine`)

**Files:**
- Modify: `Aura/Sources/GroupRide/DisplayNameEditor.swift`
- Modify: `Aura/Sources/GroupRide/GroupRideFlowView.swift` (call site)

**Interfaces:**
- Produces: `var contextLine: String? = nil` declared **immediately after `onSaved`** (so the flow's trailing-closure call keeps binding `onSaved` — SE-0286 backward scan — and Settings' `DisplayNameEditor(store:dismissesOnSave:)` stays byte-identical).

- [ ] **Step 1: Add the property** after `onSaved` in `DisplayNameEditor`:

```swift
    /// One quiet line above the field saying WHY a name is being asked for. The group-ride
    /// gate passes it; Settings (which is already titled "Crew name") leaves it nil.
    /// Declared after `onSaved` so trailing-closure call sites keep resolving.
    var contextLine: String? = nil
```

Render it at the top of the body's `VStack`, before `fieldCard`:

```swift
            if let contextLine {
                Text(contextLine)
                    .font(.subheadline)
                    .foregroundStyle(AuraTheme.textSecondary)
            }
```

- [ ] **Step 2: Update the flow call site** (`GroupRideFlowView.swift:83`):

```swift
            DisplayNameEditor(store: displayNameStore,
                              contextLine: "Pick a crew name — it's how your crew sees you.") {
                Task { await invokeEntry() }
            }
```

- [ ] **Step 3: Prove Settings unchanged** — `git diff --stat Aura/Sources/Settings/` must be empty; builder-build; sim: sign out of a crew name (or fresh install) → Start a ride → the framed prompt shows. Screenshot.

- [ ] **Step 4: Add a preview** to `DisplayNameEditor.swift` (`#Preview("Group gate — framed")` passing the contextLine) and commit — `git commit -am "feat(roh-231): the name prompt says why it's asking"`

---

### Task 9: Link-aware paste parser (`JoinCodePaste`)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/JoinCodePaste.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/JoinCodePasteTests.swift`

**Interfaces:**
- Consumes: `DeepLink.parse` (the production link grammar — one parser, not a second regex).
- Produces: `JoinCodePaste.extract(_ pasted: String) -> String`; Task 10's paste button consumes it.

- [ ] **Step 1: Failing tests:**

```swift
import Testing
import Foundation
@testable import AuraCore

struct JoinCodePasteTests {
    @Test func aSharedLinkYieldsItsCode() {
        #expect(JoinCodePaste.extract("aura://join?code=AB3KQ9RT") == "AB3KQ9RT")
    }
    @Test func aLowercasedLinkIsNormalized() {
        #expect(JoinCodePaste.extract("aura://join?code=ab3kq9rt") == "AB3KQ9RT")
    }
    @Test func surroundingWhitespaceIsTolerated() {
        #expect(JoinCodePaste.extract("  aura://join?code=AB3KQ9RT\n") == "AB3KQ9RT")
    }
    @Test func aBareCodePassesThrough() {
        #expect(JoinCodePaste.extract("AB3KQ9RT") == "AB3KQ9RT")
    }
    @Test func arbitraryTextPassesThroughForDownstreamSanitizing() {
        #expect(JoinCodePaste.extract("see you at 9, code is AB3KQ9RT") == "see you at 9, code is AB3KQ9RT")
    }
    @Test func aNonJoinAuraLinkPassesThrough() {
        #expect(JoinCodePaste.extract("aura://history") == "aura://history")
    }
}
```

- [ ] **Step 2: Verify fail, implement:**

```swift
import Foundation

/// Extracts a join code from pasted text (ROH-229). A shared link — the exact string the
/// lobby's ShareLink writes (`aura://join?code=XXXXXXXX`) — yields its code via the same
/// `DeepLink` grammar production uses; anything else passes through unchanged for the join
/// screen's usual sanitization.
public enum JoinCodePaste {
    public static func extract(_ pasted: String) -> String {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), case let .join(code)? = DeepLink.parse(url) else {
            return pasted
        }
        return code.rawValue
    }
}
```

(If `DeepLink.parse`'s signature differs — check `AuraCore/Sources/AuraCore/Navigation/` — adapt the call, not the grammar. An invalid-length code in a link fails `JoinCode` init inside the parser and correctly falls through to passthrough.)

- [ ] **Step 3: Run to green (both totals), commit** — `git commit -am "feat(roh-229): pasting the shared link fills the code"`

---

### Task 10: Join screen rebuild

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupRideJoinView.swift`

**Interfaces:**
- Consumes: `JoinCodePaste.extract` (Task 9). The `init(seed:)` already exists and Task 6 wired production to it.
- Produces: keyboard-dismissible, Join pinned above the keyboard, caption on disabled state, Dynamic Type capped. Decision 2a: the explicit Join button stays.

- [ ] **Step 1: Keyboard.** On the hidden `TextField` (after `.autocorrectionDisabled()`): `.submitLabel(.join)`. In the `.toolbar` block, add:

```swift
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFocused = false }
            }
```

- [ ] **Step 2: Pin Join.** Delete the `Spacer(minLength:)` + `joinButton` block from the main `VStack` (lines 65–69 region) and attach to the outer view (after `.background(...)`, before the tap gesture):

```swift
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: AuraTheme.Spacing.sm) {
                joinButton
                if !isValid {
                    Text("Enter the 8-character code from your host.")
                        .font(.footnote)
                        .foregroundStyle(AuraTheme.textSecondary)
                }
            }
            .padding(.horizontal, AuraTheme.Spacing.xxl)
            .padding(.top, AuraTheme.Spacing.sm)
            .padding(.bottom, AuraTheme.Spacing.lg)
            .background(AuraTheme.background)
        }
```

Add `Spacer(minLength: 0)` at the end of the main VStack so the entry cluster stays top-anchored. NO ScrollView (spec §5 — `scrollDismissesKeyboard` is a no-op when content fits; the toolbar Done is the dismissal).

- [ ] **Step 3: Paste + cap.** Paste button body: `rawInput = JoinCodePaste.extract(clipboardString)`. On the outer view: `.dynamicTypeSize(...DynamicTypeSize.accessibility1)` (the roster's cap). Code boxes stay `metricCockpit(20, relativeTo: .title3)` — do NOT bump to 24.

- [ ] **Step 4: Update the type's doc comment** — delete the "**Known gap, deferred:** once the keyboard is up it still cannot be dismissed…" paragraph and note the toolbar-Done fix (keyboard toolbar + submit label; background tap still focuses, never dismisses).

- [ ] **Step 5: Sim-verify (Tier 1, evidence REQUIRED keyboard-UP on an SE-class screen).** `xcrun simctl list devices | grep -i SE` — if no iPhone SE exists, create one: `xcrun simctl create "Aura SE" "iPhone SE (3rd generation)"` (pair with the installed runtime; if the runtime lacks SE, use the smallest available device type and say so in the PR). Boot, install the builder's build, open Crew → tap the boxes → keyboard up → screenshot: Join button AND caption must both be visible above the keyboard. Also on iPhone 17: empty/partial/valid states, Done dismisses, paste of a full share link fills the boxes. Screenshot each.

- [ ] **Step 6: Commit** — `git commit -am "feat(roh-229): join screen — pinned Join, keyboard Done, caption, link-aware paste"`

---

### Task 11: `LobbyCrewLabel` (predicate + count, package)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/LobbyCrewLabel.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/LobbyCrewLabelTests.swift`

**Interfaces:**
- Produces: `LobbyCrewLabel.isWaiting(totalRows:) -> Bool` and `LobbyCrewLabel.text(totalRows:) -> String`. Task 12's lobby consumes both.

- [ ] **Step 1: Failing tests:**

```swift
import Testing
@testable import AuraCore

struct LobbyCrewLabelTests {
    @Test func aLoneHostIsWaitingNotAOneRiderCrew() {
        #expect(LobbyCrewLabel.isWaiting(totalRows: 1))
        #expect(LobbyCrewLabel.text(totalRows: 1) == "Crew")
    }
    @Test func theCountExcludesSelf() {
        #expect(!LobbyCrewLabel.isWaiting(totalRows: 3))
        #expect(LobbyCrewLabel.text(totalRows: 3) == "Crew · 2 joined")
    }
    @Test func zeroRowsStillReadsAsWaiting() {
        #expect(LobbyCrewLabel.isWaiting(totalRows: 0))
        #expect(LobbyCrewLabel.text(totalRows: 0) == "Crew")
    }
}
```

- [ ] **Step 2: Verify fail, implement:**

```swift
import Foundation

/// The lobby's crew header + empty-state predicate (ROH-230). The row set always includes
/// self (the seed roster contains the host), so "anyone here yet?" is `count <= 1` — the old
/// `rows.isEmpty` was unreachable and a waiting host read their own name as "Crew · 1 joined".
public enum LobbyCrewLabel {
    public static func isWaiting(totalRows: Int) -> Bool { totalRows <= 1 }
    public static func text(totalRows: Int) -> String {
        isWaiting(totalRows: totalRows) ? "Crew" : "Crew · \(totalRows - 1) joined"
    }
}
```

- [ ] **Step 3: Green (both totals), commit** — `git commit -am "feat(roh-230): lobby crew label — the count excludes self, waiting is reachable"`

---

### Task 12: One code voice + three-variant empty state (components + adoption)

**Files:**
- Create: `Aura/Sources/GroupRide/JoinCodeText.swift`
- Create: `Aura/Sources/GroupRide/CrewEmptyState.swift`
- Modify: `Aura/Sources/GroupRide/GroupLobbyView.swift`
- Modify: `Aura/Sources/GroupRide/GroupRosterSheet.swift`

**Interfaces:**
- Consumes: `LobbyCrewLabel` (Task 11), `AuraTheme.Typography.metricCockpit`.
- Produces: `JoinCodeText(code:size:textStyle:color:)` (Saira cockpit + the ONE tracking token) and `CrewEmptyState(variant:)` with `.lobby` / `.rosterHost(code:)` / `.rosterGuest`. Task 18 renders lobby rows around them.

- [ ] **Step 1: `JoinCodeText.swift`:**

```swift
import SwiftUI
import AuraCore

/// The join code's one voice (ROH-230): Saira cockpit numerals, a single tracking token,
/// size parameterized per surface. The join screen's per-character boxes are the deliberate
/// exception (spec §5) — every other rendering of a code goes through this.
struct JoinCodeText: View {
    let code: String
    var size: CGFloat = 40
    var textStyle: Font.TextStyle = .largeTitle
    var color: Color = AuraTheme.textPrimary

    /// The one tracking token — do not introduce a second `.tracking`/`.kerning` on a code.
    static let tracking: CGFloat = 4

    var body: some View {
        Text(code)
            .font(AuraTheme.Typography.metricCockpit(size, relativeTo: textStyle))
            .tracking(Self.tracking)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}
```

- [ ] **Step 2: `CrewEmptyState.swift`:**

```swift
import SwiftUI
import AuraCore

/// The shared crew waiting state (ROH-230) — three real variants, one voice. The lobby
/// variant shows no code (the code card sits directly above it); the mid-ride roster is the
/// only crew surface left once the lobby is gone, so the host variant carries the code.
struct CrewEmptyState: View {
    enum Variant: Equatable {
        case lobby
        case rosterHost(code: String)
        case rosterGuest
    }
    let variant: Variant

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            Image(systemName: "person.2.wave.2")
                .font(.title2)
                .foregroundStyle(AuraTheme.textSecondary)
            Text("Waiting for your crew…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
            switch variant {
            case .lobby:
                EmptyView()
            case let .rosterHost(code):
                JoinCodeText(code: code, size: 22, textStyle: .title3, color: AuraTheme.accent)
                    .padding(.top, AuraTheme.Spacing.xs)
                Text("Share this code so they can join.")
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
            case .rosterGuest:
                Text("Riders join from the ride they were invited to.")
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AuraTheme.Spacing.xl)
    }
}

#Preview("Three variants") {
    VStack {
        CrewEmptyState(variant: .lobby)
        CrewEmptyState(variant: .rosterHost(code: "MX4T7Q2A"))
        CrewEmptyState(variant: .rosterGuest)
    }
    .background(AuraTheme.background)
    .preferredColorScheme(.dark)
}
```

- [ ] **Step 3: Adopt in the lobby.** In `GroupLobbyView`: eyebrow `Text("JOIN CODE")…tracking(1.2)` → `Text("Join code").font(.caption.weight(.semibold)).foregroundStyle(AuraTheme.textSecondary)` (sentence case, NO tracking); the code `Text(codeText)…tracking(4)` block → `JoinCodeText(code: codeText)`; `rosterSection`'s header → `Text(LobbyCrewLabel.text(totalRows: rows.count))`; the branch → `if LobbyCrewLabel.isWaiting(totalRows: rows.count) { emptyRosterState } else { …rows… }`; `emptyRosterState`'s VStack content → `CrewEmptyState(variant: .lobby)` (keep the surrounding surface-card background exactly as it is — move the background onto the CrewEmptyState call).

- [ ] **Step 4: Adopt in the roster.** `GroupRosterSheet.emptyState` body → `CrewEmptyState(variant: joinCode.map { .rosterHost(code: $0) } ?? .rosterGuest)`. Delete the now-dead monospaced/kerned code rendering (that was the third typeface).

- [ ] **Step 5: `cd Aura && xcodegen`; builder-build; sim-verify:** host lobby with nobody joined → "Join code" card + "Crew" header + reachable empty state (the previously-unreachable state — this is the visible proof of ROH-230); grep gate: `grep -rn "JOIN CODE\|kerning" Aura/Sources/GroupRide/` returns nothing. Screenshots.

- [ ] **Step 6: Commit** — `git commit -am "feat(roh-230): one join-code voice, three-variant empty state, reachable lobby waiting"`

---

### Task 13: Widen the rider palette to eight

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/RiderPaletteTests.swift`

**Interfaces:**
- Produces: `AuraPalette.riderHues.count == 8`, every hue passing every existing gate plus a new pink-clearance gate. `AuraTheme.riderColor/riderInk` need no change (they map whatever the array holds).

- [ ] **Step 1: Tighten the tests.** Add to `RiderPaletteTests`:

```swift
@Test func eightRiderHues() {
    #expect(AuraPalette.riderHues.count == 8)   // ROH-114 §D3.3's widening decision
}

/// New warm hues approach pink space; pink is the destructive token, so identity must
/// stay perceptually clear of it exactly as it does of mint (route) and amber (warning).
@Test func riderHuesStayPerceptuallyClearOfPink() {
    for h in AuraPalette.riderHues {
        #expect(deltaE(h, AuraPalette.pink) >= 15)
    }
}
```

- [ ] **Step 2: Run — `eightRiderHues` fails (count 5).** Confirm the pink gate passes for the existing five before adding anything (if it doesn't, STOP and surface it — that would be a pre-existing conflict, not this task's to silently absorb).

- [ ] **Step 3: Add three hues** to `riderHues`, starting candidates:

```swift
        RGBColor(red: 0.878, green: 0.529, blue: 0.420),  // salmon  #E0876B  (warm, mid-light)
        RGBColor(red: 0.557, green: 0.608, blue: 0.878),  // periwinkle #8E9BE0 (cool, mid)
        RGBColor(red: 0.640, green: 0.780, blue: 0.640)   // sage    #A3C7A3  (green-grey, light)
```

These are CANDIDATES: run `swift test --filter RiderPaletteTests` and iterate the constants until every gate is green (ΔE ≥ 20 mutual normal / ≥ 12 deuteranopia / ≥ 15 vs mint, amber, pink / contrast ≥ 3.0 on nearBlack / an AA monogram ink exists). Sage is the riskiest (mint proximity) — if it can't clear ΔE 15 from mint while staying distinct from cyan under deuteranopia, replace it with a light neutral-lavender (`#B8A8D8`-region) rather than fighting the gate. The tests are the design authority here (ROH-114 found ~48 mutually-passing hues, so a solution exists). Update the array's doc comment to note the count is now 8 and why (one hue per warm/cool × lightness cell).

- [ ] **Step 4: Full suite (both totals) — `PeerPaletteTests` must still pass** (assign is count-agnostic). Commit — `git commit -am "feat(roh-228): rider palette widens to eight under the full CVD/WCAG regime"`

---

### Task 14: `PeerPalette.assign` learns `reserved:`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/GroupRide/PeerPalette.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/GroupRide/PeerPaletteTests.swift`

**Interfaces:**
- Produces: `assign(userIDs:paletteCount:reserved: Set<Int> = [])` — newcomers de-collide against indices the latch has already issued (ROH-114 §D3.3: `taken` starting empty is why `assign` alone could reissue a live hue). Default `[]` keeps every existing call site and test byte-compatible.

- [ ] **Step 1: Failing tests** (append):

```swift
@Test func reservedIndicesAreNotReissuedWhileRoomRemains() {
    let id = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
    let plain = PeerPalette.assign(userIDs: [id], paletteCount: 8)[id]!
    let probed = PeerPalette.assign(userIDs: [id], paletteCount: 8, reserved: [plain])[id]!
    #expect(probed != plain)
}

@Test func aFullPaletteStillAssignsRatherThanDropping() {
    let id = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    let result = PeerPalette.assign(userIDs: [id], paletteCount: 4, reserved: [0, 1, 2, 3])
    #expect(result[id] != nil, "over-capacity collides (as today) — it never drops a rider")
}
```

- [ ] **Step 2: Verify fail, implement** — signature gains `reserved: Set<Int> = []`; the body's `var taken = Set<Int>()` becomes `var taken = reserved`. Extend the type's doc comment: the widening to 8 (Task 13) changed `stableHash % paletteCount`, so "a rider keeps their colour across rides" **broke once** at that update; and note `reserved:` exists for `RiderColorLatch` — the latch is the session authority, `assign` is its first-assignment step only.

- [ ] **Step 3: Green (both totals), commit** — `git commit -am "feat(roh-228): assign de-collides against latched indices"`

---

### Task 15: `RiderColorLatch`

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/RiderColorLatch.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/RiderColorLatchTests.swift`

**Interfaces:**
- Consumes: Task 14's `assign(…reserved:)`.
- Produces: `RiderColorLatch(paletteCount:)` with `latch(peerIDs:)` / `release(_:)` / `colorIndex(for:)` / `assignments`. Task 16 owns an instance on the session.

- [ ] **Step 1: Failing tests:**

```swift
import Testing
import Foundation
@testable import AuraCore

struct RiderColorLatchTests {
    let a = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000A")!
    let b = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000B")!
    let c = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000C")!

    /// The exact case PeerPaletteTests misses: membership changes, existing hues hold.
    @Test func aRidersHueNeverChangesWhenMembershipChanges() {
        var latch = RiderColorLatch(paletteCount: 8)
        latch.latch(peerIDs: [a, b])
        let hueA = latch.colorIndex(for: a)
        latch.latch(peerIDs: [a, b, c])       // c joins
        #expect(latch.colorIndex(for: a) == hueA)
        latch.latch(peerIDs: [a, c])          // b absent from an update — NOT a release
        #expect(latch.colorIndex(for: a) == hueA)
        #expect(latch.colorIndex(for: b) != nil, "silence is not departure (D3.3)")
    }

    @Test func newcomersDeCollideAgainstIssuedHues() {
        var latch = RiderColorLatch(paletteCount: 8)
        latch.latch(peerIDs: [a])
        latch.latch(peerIDs: [a, b, c])
        let issued = [a, b, c].compactMap { latch.colorIndex(for: $0) }
        #expect(Set(issued).count == 3, "three riders, three distinct hues")
    }

    @Test func releaseFreesTheHueForALaterJoiner() {
        var latch = RiderColorLatch(paletteCount: 2)
        latch.latch(peerIDs: [a, b])          // palette full
        latch.release(a)
        latch.latch(peerIDs: [b, c])
        let bHue = latch.colorIndex(for: b)!
        let cHue = latch.colorIndex(for: c)!
        #expect(bHue != cHue, "the released slot is reusable")
    }

    @Test func lookupMissReturnsNil() {
        let latch = RiderColorLatch(paletteCount: 8)
        #expect(latch.colorIndex(for: a) == nil)
    }
}
```

- [ ] **Step 2: Verify fail, implement:**

```swift
import Foundation

/// The one colour authority for a session's riders (ROH-114 §D3.3, adopted by ROH-228).
/// First assignment LATCHES: a rider's hue never changes for the session's lifetime — the
/// input-set-sensitive `PeerPalette.assign` alone reshuffles ~39% of existing riders per
/// membership change, which is the shipped map bug this replaces. Input is peers-minus-self
/// (self consumes no hue: white = me). A peer missing from an update keeps their hue
/// (staleness is not departure); `release` fires only on explicit `.memberLeft`, so a
/// force-quit rider never releases — bounded, and stated rather than hidden.
public struct RiderColorLatch: Equatable, Sendable {
    public private(set) var assignments: [UUID: Int] = [:]
    private let paletteCount: Int

    public init(paletteCount: Int) { self.paletteCount = max(1, paletteCount) }

    public mutating func latch(peerIDs: [UUID]) {
        let newcomers = peerIDs.filter { assignments[$0] == nil }
        guard !newcomers.isEmpty else { return }
        let fresh = PeerPalette.assign(userIDs: newcomers, paletteCount: paletteCount,
                                       reserved: Set(assignments.values))
        for (id, index) in fresh { assignments[id] = index }
    }

    public mutating func release(_ id: UUID) { assignments[id] = nil }

    public func colorIndex(for id: UUID) -> Int? { assignments[id] }
}
```

- [ ] **Step 3: Green (both totals), commit** — `git commit -am "feat(roh-228): RiderColorLatch — hues latch on first assignment"`

---

### Task 16: The session owns the latch

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideRiderColorTests.swift`

**Interfaces:**
- Consumes: Task 15's latch.
- Produces: `public private(set) var riderColors: [UUID: Int]` — refreshed alongside every `peers` snapshot; released on `.memberLeft`. Tasks 17–18 look it up; nothing recomputes.

- [ ] **Step 1: Failing tests:**

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideRiderColorTests {
    let peerA = UUID(uuidString: "DDDDDDDD-0000-0000-0000-00000000000A")!
    let peerB = UUID(uuidString: "DDDDDDDD-0000-0000-0000-00000000000B")!

    func makeLiveSession() async -> GroupRideSession {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        let session = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                       displayNameProvider: { "Jamie" })
        await session.create(route: nil)
        await session.beginLiveSession()
        return session
    }

    func position(_ id: UUID) -> TransportEvent {
        .position(LivePositionPayload(userID: id, coordinate: Coordinate(latitude: 1, longitude: 2),
                                      progressMeters: 0, recordedAt: Date(), motionState: .moving))
    }

    @Test func peersGetLatchedHuesAndSelfGetsNone() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        #expect(session.riderColors[peerA] != nil)
        #expect(session.riderColors[session.selfUserID!] == nil, "white = me: self holds no hue")
    }

    @Test func aHueSurvivesMembershipChange() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        let hue = session.riderColors[peerA]
        await session.ingest(position(peerB))
        #expect(session.riderColors[peerA] == hue)
    }

    @Test func memberLeftReleasesTheHue() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        await session.ingest(.memberLeft(peerA))
        #expect(session.riderColors[peerA] == nil)
    }
}
```

- [ ] **Step 2: Verify fail, implement.** Stored state (near `peers`):

```swift
/// Latched identity hues, peers-minus-self (ROH-228 / ROH-114 §D3.3). Surfaces LOOK UP —
/// the lobby, the roster empty state, and the map driver all read this one dictionary;
/// none may call `PeerPalette.assign` themselves.
public private(set) var riderColors: [UUID: Int] = [:]
private var colorLatch = RiderColorLatch(paletteCount: AuraPalette.riderHues.count)
```

Private helper:

```swift
private func refreshRiderColors() {
    colorLatch.latch(peerIDs: peers.map(\.userID).filter { $0 != selfUserID })
    riderColors = colorLatch.assignments
}
```

Call `refreshRiderColors()` immediately after **every** `peers = session.peers` assignment (`beginLiveSession`, `tick`, `ingest`, and Task 2's `mergeLobbyRoster`) — grep `peers = session.peers` to find all four. In `ingest`'s `.memberLeft` case, add `colorLatch.release(id)` before the toast append. The latch itself is NOT reset in `teardownLive` (an ended session's surfaces may still render a last frame; a fresh session object starts fresh anyway — `GroupRideFlowView` constructs a new `GroupRideSession` per entry).

- [ ] **Step 3: Green (new + both totals), commit** — `git commit -am "feat(roh-228): the session owns the colour authority"`

---

### Task 17: Map driver reads the latch (REBASE CHECK FIRST)

**Files:**
- Modify: `Aura/Sources/GroupRide/PeerAnnotations.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift:386-391` (`syncPeers` — two `updateSet` calls)

**Interfaces:**
- Consumes: `session.riderColors` (Task 16).
- Produces: `updateSet(peers:selfUserID:nameMap:riderColors:reduceMotion:now:)` — `PeerPalette.assign` leaves the driver; the shipped mid-ride reshuffle dies here.

- [ ] **Step 1: REBASE CHECK.** `git fetch origin && git log --oneline origin/main -5`. If the identity-carriers branch has merged to main since this branch was cut, merge main into this branch NOW and resolve `NavigateHUDView.swift` before touching it (their Tasks 3/9/12/13 all edit that file). If their branch is still unmerged, proceed — but keep this task's `NavigateHUDView` diff to exactly the two `updateSet` call lines, and note the coordination in the commit message.

- [ ] **Step 2: Change the driver.** In `PeerAnnotationDriver.updateSet`, add the parameter `riderColors: [UUID: Int]` (after `nameMap:`) and replace the `colorIndex = PeerPalette.assign(…)` line with:

```swift
        // Latched lookup (ROH-228): the session is the one colour authority. A lookup miss
        // (a peer visible before the session's snapshot refreshed) falls back to the same
        // stable hash the latch would start from — transient, and never reshuffles neighbours.
        let paletteCount = max(1, AuraTheme.riderPalette.count)
        colorIndex = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, riderColors[id] ?? PeerPalette.assign(userIDs: [id], paletteCount: paletteCount)[id] ?? 0)
        })
```

- [ ] **Step 3: Update the two call sites** in `NavigateHUDView.syncPeers()`: the nil-session branch passes `riderColors: [:]`; the live branch passes `riderColors: groupSession.riderColors`.

- [ ] **Step 4: Update the `PeerAnnotations` preview** — it calls `updateSet` twice; give it a frozen assignment consistent with the latch (`riderColors: [maraID: 0, miraID: 1, devonID: 2, samID: 3]`) and change its `UUID()` ids to frozen `UUID(uuidString:)!` literals (evidence rule).

- [ ] **Step 5: Builder-build; sim-verify Tier 1:** the preview renders four distinctly-hued dots (screenshot via Xcode preview or the sim harness). The real reshuffle fix is Tier 2 (two-phone, Task 20's issue). Commit — `git commit -am "fix(roh-228): map peer hues come from the latch — no more mid-ride reshuffle"`

---

### Task 18: Lobby identity rows (`CrewMonogram`, white = me, You/Host markers)

**Files:**
- Create: `Aura/Sources/GroupRide/CrewMonogram.swift`
- Modify: `Aura/Sources/GroupRide/GroupLobbyView.swift` (rows + row view)

**Interfaces:**
- Consumes: `session.riderColors` (Task 16), `RiderMonogram.assign`, `session.hostID`, board reference `2026-08-31-crew-identity-board.svg`.
- Produces: lobby rows with identity discs; self = white disc + real name + "You" marker; host row + "Host" marker.

- [ ] **Step 1: `CrewMonogram.swift`:**

```swift
import SwiftUI
import AuraCore

/// A rider's identity disc (ROH-228, gate-1 board): latched hue + monogram for a peer;
/// WHITE for self — "white = me" is the puck grammar, and the rider marker is never
/// accent-mint. Colour is looked up, never computed here.
struct CrewMonogram: View {
    /// nil = self: white disc, label inked in the background colour.
    let colorIndex: Int?
    let label: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(colorIndex.map { AuraTheme.riderColor($0) } ?? AuraTheme.textPrimary)
                .frame(width: size, height: size)
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(colorIndex.map { AuraTheme.riderInk($0) } ?? AuraTheme.background)
        }
        .accessibilityHidden(true)   // the row's combined label carries the name
    }
}
```

- [ ] **Step 2: Rebuild the lobby rows.** `LobbyRosterRow` becomes:

```swift
private struct LobbyRosterRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let isSelf: Bool
    let isHost: Bool
    let colorIndex: Int?   // nil for self (white disc)
    let monogram: String
}
```

`GroupLobbyView.rows` becomes:

```swift
    private var rows: [LobbyRosterRow] {
        let peerNames: [UUID: String] = Dictionary(uniqueKeysWithValues:
            session.peers.filter { $0.userID != session.selfUserID }
                .map { ($0.userID, DisplayName.forDisplay(session.nameMap[$0.userID] ?? $0.displayName)) })
        let monograms = RiderMonogram.assign(names: peerNames)   // self contributes no monogram
        return session.peers.map { peer in
            let isSelf = peer.userID == session.selfUserID
            let resolved = DisplayName.forDisplay(session.nameMap[peer.userID] ?? peer.displayName)
            let name = (isSelf && resolved.isEmpty) ? "You" : resolved
            return LobbyRosterRow(
                id: peer.userID, name: name, isSelf: isSelf,
                isHost: peer.userID == session.hostID,
                colorIndex: isSelf ? nil : session.riderColors[peer.userID],
                monogram: isSelf ? String(name.prefix(1)).uppercased()
                                 : (monograms[peer.userID] ?? "?"))
        }
    }
```

`LobbyRosterRowView` body becomes (markers per the board — quiet capsules, sentence case):

```swift
    var body: some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            CrewMonogram(colorIndex: row.colorIndex, label: row.monogram)
            Text(row.name)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                .lineLimit(1)
            if row.isSelf && row.name != "You" { marker("You") }
            if row.isHost { marker("Host") }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AuraTheme.Spacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [row.isSelf ? "\(row.name), you" : "\(row.name) joined"]
        if row.isHost { parts.append("host") }
        return parts.joined(separator: ", ")
    }

    private func marker(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(AuraTheme.textSecondary)
            .padding(.horizontal, AuraTheme.Spacing.xs)
            .padding(.vertical, 2)
            .background(AuraTheme.textSecondary.opacity(0.14), in: Capsule())
    }
```

(The old always-accent `Circle().fill(AuraTheme.accent)` disc dies here — that was the third monogram implementation ignoring the rider palette.)

- [ ] **Step 3: `cd Aura && xcodegen`; builder-build.** The existing lobby previews drive real sessions — they now show hued discs and markers with no preview changes. Sim-verify Tier 1: host lobby (self = white disc + Host marker once a friend joins and rows render), screenshot against the board SVG side-by-side.

- [ ] **Step 4: Commit** — `git commit -am "feat(roh-228): lobby identity rows — latched hues, white = me, You/Host markers"`

---

### Task 19: Roster "You YOU" fix

**Files:**
- Modify: `AuraCore/Sources/AuraCore/GroupRide/GroupRosterViewData.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/GroupRide/GroupRosterViewDataTests.swift`
- Modify: `Aura/Sources/GroupRide/GroupRosterSheet.swift` (marker guard, one line)

**Interfaces:**
- Produces: the self row's name column shows the real display name (marker stays); `GroupRosterViewData.selfLabel` becomes `public` so the view's guard and the tests share the constant. Roster avatars/status grammar/sort UNTOUCHED (decision 3a).

- [ ] **Step 1: Failing tests** (append to the existing suite, matching its fixture style):

```swift
@Test func theSelfRowShowsTheRealNameWhenTheRosterResolvesIt() {
    let selfID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!
    let rows = GroupRosterViewData.rows(peers: [], nameMap: [selfID: "Jamie Rivera"],
                                        selfUserID: selfID, selfProgress: 0, isImperial: true)
    #expect(rows[0].name == "Jamie Rivera")
    #expect(rows[0].isSelf)
}

@Test func anUnresolvedSelfNameFallsBackToYou() {
    let selfID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000002")!
    let rows = GroupRosterViewData.rows(peers: [], nameMap: [:],
                                        selfUserID: selfID, selfProgress: 0, isImperial: true)
    #expect(rows[0].name == GroupRosterViewData.selfLabel)
}
```

- [ ] **Step 2: Verify fail, implement.** `private static let selfLabel` → `public static let selfLabel = "You"`. In `rows`, the name line becomes:

```swift
            let resolved = DisplayName.forDisplay(nameMap[peer.userID] ?? peer.displayName)
            let name = (isSelf && resolved.isEmpty) ? Self.selfLabel : resolved
```

(The fabricated self `RidePeer` carries `displayName: ""`, and `roster()` includes self, so `nameMap` resolves it in production.) In `RosterRowView`, guard the marker so an unresolved fallback can't read "You YOU" again:

```swift
            if row.isSelf && row.name != GroupRosterViewData.selfLabel {
                Text("YOU") // existing style, unchanged
```

- [ ] **Step 3: Green (both totals; existing roster tests asserting "You" for self may need the resolved-name update — that assertion WAS the bug), builder-build, sim screenshot of the mid-ride roster.** Commit — `git commit -am "fix(roh-228): the roster's self row is a name, not You YOU"`

---

### Task 20: Slice close — gates, evidence, PR, review, board

**Files:** none new (evidence + process).

- [ ] **Step 1: Full local gate.** Repo root: `swiftlint --strict` clean; `cd AuraCore && swift test` — BOTH totals green; builder: clean app build.
- [ ] **Step 2: Whole-slice before/after evidence set** (Tier 1, for the PO gate): join screen (empty / partial / valid / keyboard-up SE / caption), lobby (waiting / filled with hued rows + markers), roster (self-named row, empty-state voices), flow (both loading copies, rejected surface, connection surface, framed name prompt), map preview (hued dots). Pair each with its "before" from the audit set where one exists.
- [ ] **Step 3: Push + PR** to `main` from `claude/premium-ui-design-audit-8f663d`, body stating: Tier 1 evidence inline; **Tier 2 queued** (A0 two-phone fill, per-device hue stability across a mid-ride join) with the golden-ride/E2E caveat that no CI path exercises the poll against a real second device; the five child issues; the spec/plan/board paths.
- [ ] **Step 4: Whole-branch review** on the most capable model (Agent-tool-less reviewer), findings adjudicated before merge.
- [ ] **Step 5: PO gate — STOP AND WAIT.** Post the before/after set; do not merge until the PO signs off (their standing mandate: nothing visual ships in one sweep).
- [ ] **Step 6: Board.** Create the Tier-2 Verification issue (two-phone: host lobby fills within one poll interval; a mid-ride joiner's hue is stable and map-vs-lobby consistent on one device) appended to the existing two-phone queue; move ROH-227/228/229/230/231 through In Review → Done as the PR merges (revert any Linear auto-completion that fires early — ROH-224-style); ROH-225 stays open until the Tier-2 pass lands or is explicitly waived.

---

## Self-review notes (v1)

- Spec coverage walked §3→A0 (Tasks 1–2), §4→A (13–19), §5→B (9–10), §6→C (11–12), §7→D (3–8), §8 verification (per-task steps + Task 20), §10 criteria each traceable to a task.
- The spec's §10.6 "no uppercase tracked eyebrows in the group module": Task 12's grep gate covers "JOIN CODE"; the join screen's `or join with a code` divider is lowercase already; the roster "YOU" marker is exempted by spec §4 (marker stays).
- Type consistency: `riderColors: [UUID: Int]` (Tasks 16→17→18), `EntryFailureReason` (3→4→7), `LobbyCrewLabel` (11→12), `JoinCodePaste.extract` (9→10), `mergeRoster` (1→2), `assign(…reserved:)` (14→15).
- Deliberately NOT here: server migrations, `.mapCard`, Theme CTA changes, code-reveal motion, QR join, open-ride crew layer (ROH-114 Plan 2), the `selfUserID ?? UUID()` latent default in `NavigateHUDView+GroupCrew.swift:28` (identity-carriers file boundary; follow-up once their branch lands).
