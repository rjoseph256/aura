# Crew Family (ROH-225) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Version:** v2, reconciled 2026-09-01 after the 2-reviewer adversarial plan gate (skeptic + architecture lenses). v1 is dead — do not resurrect its mechanisms. The reconciliation log at the bottom records every adjudication.

**Goal:** Make the group-ride lobby actually fill, give riders stable identity hues on map + lobby, and turn the join/waiting/failure flows into honest, recoverable surfaces.

**Architecture:** Pure seams in AuraCore/AuraKit (roster merge, lobby poll cadence, failure classifier, color latch, the `CrewIdentity` bundle, paste parser, count label) drive thin SwiftUI adoption in the app target. `GroupRideSession` is the single owner of live state — one `snapshotPeers` writer keeps `peers`, the latch, and `CrewIdentity` atomic; surfaces look up, never recompute.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`@Test`/`#expect`), SwiftPM package `AuraCore` (AuraCore pure + AuraKit session layer), xcodegen app project, Supabase backend (NO server changes).

**Spec:** `docs/superpowers/specs/2026-08-31-crew-family-design.md` (v2, PO-approved with decisions 1a/2a/3a). Visual reference: `docs/superpowers/specs/2026-08-31-crew-identity-board.svg`.

**Board:** ROH-227 (A0, Tasks 1–2) · ROH-231 (D, Tasks 3–8) · ROH-229 (B, Tasks 9–10) · ROH-230 (C, Tasks 11–12) · ROH-228 (A, Tasks 13–19) · Task 20 closes the slice. Move each issue Todo → In Progress → In Review → Done as its tasks run; revert any Linear auto-completion that fires early.

## Global Constraints

- **Baseline is the post-merge tree.** The identity-carriers branch merged to main as PR #140 (`5b29f6f`) and main is merged into this branch (`f4c5768`). There is NO cross-branch coordination left — v1's file-boundary language is void. Line numbers cite `f4c5768`; locate by symbol if drifted. Task 0 verifies the baseline is green before anything else.
- **SwiftLint budgets, measured** (`.swiftlint.yml`: `--strict` fails on warnings; `file_length` warning 500; `type_body_length` default 250; `function_parameter_count` default 5):
  - `GroupRideSession.swift` = 465 lines, main class body 232/250. Task 2 relocates the entry/start methods into a same-file extension FIRST (the file's own End/Leave extension is the precedent) so Tasks 2/4/16 have body headroom. If the file passes 500 lines, add the documented `// swiftlint:disable file_length` header Task 2 specifies — the repo's targeted-disable-with-justification precedent (`MapboxGuidanceSession.swift:259` et al.).
  - `NavigateHUDView.swift` = 498/500. Task 17's call-site edit must be **net-zero lines** (the `CrewIdentity` param replaces `nameMap`, same line count).
  - `PeerAnnotationDriver.updateSet` stays at **5 parameters** (the `CrewIdentity` bundle replaces `nameMap`, absorbing colors + monograms).
- **No new motion.** The only animation is the lobby's existing `.easeOut(duration: 0.22)` on `rows.count` (`GroupLobbyView.swift:81`).
- **No Theme-wide changes**: no CTAButtonStyle edits, no `.mapCard`, no gradients, no pulsing.
- **Sentence case** for all new/changed copy; no uppercase tracked eyebrows in the group module. The roster's existing "YOU" marker style stays (a marker, not an eyebrow — spec §4).
- **`GroupRideSession.Phase` stays payload-free**; failure reason is a property alongside phase, cleared at the top of every attempt, written adjacent to the phase with no suspension between.
- **The ROH-81 single structural branch in `GroupRideFlowView.content` is untouched.**
- **Navigation is single-write** (`replaceTop`-style); no `dismiss()` + push; no new NavigationStack.
- **No server changes.** The join oracle stays generic (ROH-226).
- **Async closures are NEVER default arguments** (ROH-110): nil-default + init-body construction. `GroupRideSession`'s init parameter order is pinned once: `(backend, transport, displayNameProvider, cadence, endTimeout, entryTimeout, lobbyPollInterval, sleep, pollSleep)`.
- **Two clocks, two seams**: `sleep` feeds `withTimeout` (timeout semantics — cancelled timers are awaited); `pollSleep` feeds the lobby poll (cadence semantics). Tests gate `pollSleep` only. Never route both through one closure — a cancelled `withTimeout` timer would broadcast-wake the poll (gate finding).
- Previews used as evidence use **frozen UUIDs** and valid 8-character codes from `JoinCode.charset`.
- **`swiftlint --strict` from the repo root; `swift test` in `AuraCore/` prints two totals — both green. `cd Aura && xcodegen` after every app-target file add/remove.** Builds via the `apple-platform-build-tools` builder; implementers write app-target SwiftUI directly.
- **Verification tiers:** Tier 1 sim per task; **Tier 2 two-phone, queued** (A0 fill, per-device hue stability). A0 is the merge-worthiness bar.
- **PO gate:** whole-slice before/after set before merge (Task 20). Settled decisions stay settled (white = me; roster status colors; explicit Join + caption; roster poll).

---

### Task 0: Verify the merged baseline

The reconciliation session already merged `origin/main` (`f4c5768`). Before Task 1:

- [x] **Step 1:** `cd AuraCore && swift test` — both totals green. *(Verified 2026-09-01: 325 XCTest + 937 swift-testing, 0 failures.)*
- [x] **Step 2:** `swiftlint --strict` from the repo root — clean. *(0 violations in 520 files.)*
- [x] **Step 3:** Builder: app scheme builds for simulator. *(BUILD SUCCEEDED, iPhone 17 sim.)*
- [x] **Step 4:** Nothing to commit if green (the merge commit exists). If anything is red, STOP and fix the merge before any slice work — do not interleave. *(Green — baseline is `f4c5768`.)*

---

### Task 1: Roster merge seam (`LivePresenceState.merge` + `RideSession.mergeRoster`)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/GroupRide/LivePresenceState.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/RideSession.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/LivePresenceStateTests.swift` (extend)

**Interfaces:**
- Produces: `LivePresenceState.merge(roster: [RidePeer])` (mutating, idempotent, never touches known peers) and `RideSession.mergeRoster(_ members: [RidePeer])` — Task 2's poll consumes the latter. A merged peer has `lastUpdate == nil`, so `PeerStatusReducer` keeps it `.awaiting` under the staleness ticker (verified at the gate).

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

- [ ] **Step 2:** `cd AuraCore && swift test --filter LivePresenceStateTests` → FAIL: `merge` not defined.

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

- [ ] **Step 4:** Filter run green, then the full suite (both totals).
- [ ] **Step 5:** `git add -A && git commit -m "feat(roh-227): roster merge seam — presence learns joined members without a position"`

---

### Task 2: Lobby roster poll in `GroupRideSession`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` (spies)
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideLobbyPollTests.swift`

**Interfaces:**
- Consumes: Task 1's `mergeRoster`; a NEW dedicated `pollSleep` clock seam (nil-defaulted, ROH-110 pattern).
- Produces: while `phase == .lobby`, `peers` gains joined members within one `lobbyPollInterval` (default 4 s). The poll **restarts on every entry to `.lobby`** — including an authoritative reconcile that corrects a phantom start (`RideLifecycle.swift:36-42` moves riders backward; `GroupRideSessionLifecycleSyncTests` walks that path) — and is NOT coupled to `beginLiveSession`'s one-shot `didBeginLive` latch. New init params: `lobbyPollInterval: Duration = .seconds(4)`, `pollSleep: (@Sendable (Duration) async throws -> Void)? = nil` (pinned order: after `sleep`).

- [ ] **Step 1: Lint-budget prep (separate commit).** Move `create(route:)`, `join(code:)`, `startRiding()`, `attemptStart()`, and `retryStartIfNeeded()` verbatim into a new same-file extension:

```swift
// MARK: - Entry & start (create / join / startRiding)
//
// Same-file extension purely for SwiftLint's `type_body_length` ceiling (the main body
// measured 232/250 before this slice), following the End / Leave extension's precedent
// below. Private stored-state access is unaffected; behavior is identical.
extension GroupRideSession {
```

Run both totals + `swiftlint --strict` (must be clean — a pure move). Commit: `git commit -am "refactor(roh-227): relocate entry/start methods to a same-file extension (lint budget)"`. If `wc -l` on the file ever exceeds 500 during Tasks 2/4/16, add at the very top:

```swift
// swiftlint:disable file_length
// The doc comments in this file are load-bearing incident history (ROH-110 frame sizing,
// ROH-167 begin-live latching, ROH-81 teardown semantics). Trimming them to fit the
// file ceiling would delete the reasons the code is shaped this way; the type- and
// function-body ceilings still apply in full.
```

- [ ] **Step 2: Add the spies.** In `InMemoryGroupRideBackend.Store` (existing spy block, same comment style): `var rosterCallCount = 0   // test spy: how many times roster() ran` and `var joinCallCount = 0   // test spy: how many times joinRide ran`. Increment each at the top of `roster(rideID:)` / `joinRide(code:)`. Tests read them as `backend.store.<spy>` (house idiom).

- [ ] **Step 3: Write the failing tests** (new file):

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Releases the session's injected `pollSleep` one interval at a time, so the poll cadence
/// is test-driven rather than wall-clock. LEVEL-TRIGGERED: a release with nobody parked is
/// banked as a permit, so a release racing task startup is never lost (gate finding — the
/// edge-triggered version lost the wakeup 200/200 when release beat the task's first park).
/// Cancellation-aware: a cancelled sleeper resumes immediately so `teardownLive` can unwind.
actor SleepGate {
    private var permits = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || permits > 0 {
                    if permits > 0 { permits -= 1 }
                    continuation.resume()
                } else {
                    nextID += 1
                    waiters[nextID] = continuation
                }
            }
        } onCancel: {
            Task { await self.drain() }
        }
    }

    func release() {
        if let first = waiters.keys.sorted().first, let continuation = waiters.removeValue(forKey: first) {
            continuation.resume()
        } else {
            permits += 1
        }
    }

    private func drain() {
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
            pollSleep: { _ in await gate.wait() })
        await session.create(route: nil)
        return (session, backend)
    }

    @discardableResult
    func joinGuest(named name: String, sharing backend: InMemoryGroupRideBackend,
                   code: JoinCode) async throws -> InMemoryGroupRideBackend {
        let guest = InMemoryGroupRideBackend(sharing: backend)
        try await guest.signIn(idToken: "guest-\(name)", nonce: "n", displayName: name)
        _ = try await guest.joinRide(code: code)
        return guest
    }

    @Test func aJoinerAppearsAfterOnePollIntervalWithNoPosition() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        await session.beginLiveSession()
        try await joinGuest(named: "Priya", sharing: backend, code: session.joinCode!)
        #expect(session.peers.count == 1, "not yet — no interval has elapsed")
        await gate.release()
        await settle { session.peers.count == 2 }
        #expect(session.peers.count == 2)
        #expect(session.peers.contains { $0.status == .awaiting && session.nameMap[$0.userID] == "Priya" })
    }

    @Test func thePollIsIdempotentWithTheSeedRoster() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        try await joinGuest(named: "Priya", sharing: backend, code: session.joinCode!)
        await session.beginLiveSession()          // seed already contains Priya
        let seeded = session.peers.count
        let calls = backend.store.rosterCallCount
        await gate.release()
        // POSITIVE CONTROL first (gate finding: without it this test passes vacuously
        // whenever the poll simply never ran).
        await settle { backend.store.rosterCallCount > calls }
        #expect(backend.store.rosterCallCount > calls, "the poll actually re-fetched")
        #expect(session.peers.count == seeded, "re-polling the same roster adds nothing")
    }

    @Test func thePollStopsWhenTheRideEnds() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        await session.beginLiveSession()
        await session.end()                       // teardownLive cancels the poll
        await settle { session.phase == .ended }
        let calls = backend.store.rosterCallCount
        await gate.release()                      // banked or wakes a straggler — guard must hold
        await settle { false }
        #expect(backend.store.rosterCallCount == calls, "no roster fetch after teardown")
    }

    /// The gate's headline A0 finding: an optimistic `.rideStarted` followed by an
    /// authoritative reconcile back to `.lobby` (the phantom-start correction that
    /// `GroupRideSessionLifecycleSyncTests` already exercises) must NOT kill the poll —
    /// v1 coupled the poll to `beginLiveSession`'s one-shot latch and died here silently.
    @Test func thePollSurvivesAPhantomStartRoundTrip() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        await session.beginLiveSession()
        await session.ingest(.rideStarted)
        #expect(session.phase == .riding)
        await session.reconcileFromStatus()       // server never stamped started_at
        #expect(session.phase == .lobby)
        try await joinGuest(named: "Priya", sharing: backend, code: session.joinCode!)
        await gate.release()
        await settle { session.peers.count == 2 }
        #expect(session.peers.count == 2, "the poll is alive after the round trip")
    }
}
```

- [ ] **Step 4:** Run `swift test --filter GroupRideLobbyPollTests` → FAIL (no `pollSleep` parameter; no poll).

- [ ] **Step 5: Implement.** Main class body gains only stored state (the methods go in a new extension):

```swift
/// How often the lobby re-reads the roster so joiners appear pre-ride (ROH-227, decision 1a).
private let lobbyPollInterval: Duration
/// The poll's cadence clock — SEPARATE from `sleep` on purpose: `sleep` feeds `withTimeout`,
/// whose cancelled timers are awaited, and a shared gate would broadcast those cancellations
/// into the poll (plan-gate finding). nil-defaulted per ROH-110; see `sleep`'s note.
private let pollSleep: @Sendable (Duration) async throws -> Void
private var lobbyPollTask: Task<Void, Never>?
```

Init (pinned order; both defaulted, no call-site changes):

```swift
public init(backend: any GroupRideBackend, transport: any RideSessionTransport,
            displayNameProvider: @escaping @Sendable () -> String, cadence: LiveShareCadence = .init(),
            endTimeout: Duration = .seconds(4),
            entryTimeout: Duration = .seconds(10),
            lobbyPollInterval: Duration = .seconds(4),
            sleep: (@Sendable (Duration) async throws -> Void)? = nil,
            pollSleep: (@Sendable (Duration) async throws -> Void)? = nil) {
    // …existing assignments…
    self.entryTimeout = entryTimeout            // stored property lands in Task 4; add both
    self.lobbyPollInterval = lobbyPollInterval  // params NOW so the init is edited once
    self.sleep = sleep ?? { try await Task.sleep(for: $0) }
    self.pollSleep = pollSleep ?? { try await Task.sleep(for: $0) }
}
```

(Add `private let entryTimeout: Duration` now too — Task 4 uses it; one init edit, not two.)

New same-file extension:

```swift
// MARK: - Lobby roster poll (ROH-227)
extension GroupRideSession {
    /// Re-reads the roster on a cadence while the rider waits in the lobby, so a joining
    /// friend appears without a `.position` (which never flows pre-ride). Restarted on
    /// EVERY entry to `.lobby` — including an authoritative reconcile that corrects a
    /// phantom start — so it is deliberately not latched by `didBeginLive`. Self-terminates
    /// on any phase exit; cancelled in `teardownLive`; idempotent with the seed because
    /// `mergeRoster` skips known members.
    func startLobbyPoll() {
        lobbyPollTask?.cancel()
        lobbyPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .lobby else { return }
                try? await self.pollSleep(self.lobbyPollInterval)
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
}
```

Wiring — the poll starts on every `.lobby` edge:
- End of `beginLiveSession()` (after `peers = session.peers`): `if phase == .lobby { startLobbyPoll() }`
- In `applyLifecyclePhase`, the `.lobby` case becomes `phase = .lobby; startLobbyPoll()` (restart is idempotent — `startLobbyPoll` cancels any prior task first).
- In `teardownLive(_:)`: `lobbyPollTask?.cancel(); lobbyPollTask = nil`.

- [ ] **Step 6:** All four new tests green, then the full suite (both totals) and `swiftlint --strict`.
- [ ] **Step 7:** `git commit -am "feat(roh-227): lobby roster poll — the room fills, and survives a phantom-start round trip"`

---

### Task 3: Entry-failure taxonomy (`connectionFailed` + classifier + spies)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift` (add enum case)
- Create: `AuraCore/Sources/AuraKit/GroupRide/EntryFailure.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` (spies)
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/EntryFailureTests.swift`

**Interfaces:**
- Produces: `GroupRideError.connectionFailed`; `EntryFailureReason { connectionFailed, rejected }`; `EntryFailure.isConnectionFailure(_:)` (walks one level of `NSUnderlyingErrorKey` — Supabase auth errors can wrap the transport error); spies `forceJoinError: GroupRideError?`, `hangJoin`, `hangCreate` (a bare `try await Task.sleep(for: .seconds(1000))` before the normal logic — the exact `hangEndLeave` mechanism at `InMemoryGroupRideBackend.swift:108`, whose `CancellationError` is what `withTimeout` converts to `TimeoutError`).

- [ ] **Step 1: Failing tests:**

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
    @Test func aWrappedURLErrorIsUnwrappedOneLevel() {
        let wrapped = NSError(domain: "auth", code: 1,
                              userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        #expect(EntryFailure.isConnectionFailure(wrapped))
    }
    @Test func aServerRejectionIsNotAConnectionFailure() {
        #expect(!EntryFailure.isConnectionFailure(GroupRideError.joinFailed))
    }
    @Test func cancellationIsNotAConnectionFailure() {
        // withTimeout owns the CancellationError → TimeoutError conversion; the classifier
        // must not pre-empt it (and Task 5's backend rethrows cancellation for the same reason).
        #expect(!EntryFailure.isConnectionFailure(CancellationError()))
    }
    @Test func anUnknownErrorDefaultsToRejected() {
        #expect(!EntryFailure.isConnectionFailure(SomeError()))
    }
}
```

- [ ] **Step 2: Verify fail, implement.** `GroupRideError` gains:

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
    /// as opposed to answering and saying no. `CancellationError` is deliberately NOT a
    /// connection failure — `withTimeout` owns that conversion (a genuine timeout surfaces
    /// here as `TimeoutError`). Walks one level of underlying error because SDK auth
    /// wrappers can carry the transport error inside.
    public static func isConnectionFailure(_ error: any Error) -> Bool {
        if error is TimeoutError { return true }
        if (error as? GroupRideError) == .connectionFailed { return true }
        if error is URLError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSURLErrorDomain || underlying.domain == NSPOSIXErrorDomain
        }
        return false
    }
}
```

Spies in `Store` (existing block, same comment style): `var forceJoinError: GroupRideError?   // test spy`, `var hangJoin = false   // test spy: park joinRide until cancelled`, `var hangCreate = false   // test spy: park createRide until cancelled`. In `joinRide`, before the normal logic: `if store.hangJoin { try await Task.sleep(for: .seconds(1000)) }` then `if let forced = store.forceJoinError { throw forced }`. Same `hangCreate` line at the top of `createRide`.

- [ ] **Step 3:** New tests green; `swift build` then the full suite — the new enum case may break exhaustive switches; fix any the compiler flags.
- [ ] **Step 4:** `git commit -am "feat(roh-231): entry-failure taxonomy — connection vs rejection, classifier + spies"`

---

### Task 4: Session carries the reason; attempts are bounded, re-enterable, and re-entrancy-guarded

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEntryFailureTests.swift`

**Interfaces:**
- Consumes: Task 3's types; `withTimeout(_:sleep:operation:)`; the `entryTimeout` stored property Task 2 already added to the init.
- Produces: `public private(set) var entryFailureReason: EntryFailureReason?`; `create`/`join` (now in the Task-2 extension) reset `entryFailureReason = nil` + `phase = .idle` at attempt top (after the name guard) so a retry re-enters the loading surface; both wrapped in `withTimeout(entryTimeout, sleep:)`; a `finishRide`-style re-entrancy latch `isEntering` (gate finding: a double-tapped Try-again would otherwise create two server-side rides and bind the live layer to the orphan).

**Known residual, stated on purpose (gate finding):** a join that times out CLIENT-side after the server committed the membership leaves a ghost `.awaiting` member in the host's lobby (the RPC ran; only the response was slow), holding one of the 8 cap slots until the ride ends. `join_ride` is idempotent, so the approved Try-again path (re-join with the preserved code) self-heals it; the residual is a rider who times out and then abandons. No client-side fix exists without the rideID the timed-out call would have returned. Task 20 states this in the PR and the Tier-2 issue.

- [ ] **Step 1: Failing tests:**

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

    func makeBackend() async -> InMemoryGroupRideBackend {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        return backend
    }

    @Test func anUnknownCodeIsARejection() async {
        let session = makeSession(backend: await makeBackend())
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        #expect(session.entryFailureReason == .rejected)
    }

    @Test func aTransportFailureIsAConnectionFailure() async {
        let backend = await makeBackend()
        backend.store.forceJoinError = .connectionFailed
        let session = makeSession(backend: backend)
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        #expect(session.entryFailureReason == .connectionFailed)
    }

    @Test func aHungJoinResolvesToAConnectionFailureNotAnEternalSpinner() async {
        let backend = await makeBackend()
        backend.store.hangJoin = true
        let session = makeSession(backend: backend, sleep: { _ in })   // instant entry timeout
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        #expect(session.entryFailureReason == .connectionFailed)
    }

    @Test func aHungCreateResolvesToAConnectionFailure() async {
        let backend = await makeBackend()
        backend.store.hangCreate = true
        let session = makeSession(backend: backend, sleep: { _ in })
        await session.create(route: nil)
        #expect(session.phase == .createFailed)
        #expect(session.entryFailureReason == .connectionFailed)
    }

    @Test func aRetryClearsTheReasonAndSucceeds() async {
        let session = makeSession(backend: await makeBackend())
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)   // fails: no such ride
        #expect(session.entryFailureReason == .rejected)
        await session.create(route: nil)                            // fresh attempt succeeds
        #expect(session.entryFailureReason == nil, "cleared at the top of the attempt")
        #expect(session.phase == .lobby)
    }

    /// The retry surface shows loading again because the attempt resets phase to `.idle` —
    /// observable mid-flight against a parked backend (gate finding: v1 asserted this nowhere).
    @Test func aRetryReEntersTheLoadingPhaseWhileInFlight() async {
        let backend = await makeBackend()
        let session = makeSession(backend: backend)
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        backend.store.hangJoin = true
        let attempt = Task { await session.join(code: JoinCode(rawValue: "AAAA2222")!) }
        for _ in 0..<500 where session.phase != .idle { await Task.yield() }
        #expect(session.phase == .idle, "the second attempt re-entered loading")
        attempt.cancel()
        _ = await attempt.value
    }

    /// Two taps on Try-again must not create two rides (gate finding: create/join had no
    /// re-entrancy guard where finishRide has isEnding).
    @Test func concurrentJoinAttemptsCollapseToOne() async {
        let backend = await makeBackend()
        backend.store.hangJoin = true
        let session = makeSession(backend: backend)
        let first = Task { await session.join(code: JoinCode(rawValue: "AAAA2222")!) }
        for _ in 0..<500 where backend.store.joinCallCount == 0 { await Task.yield() }
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)   // second tap: rejected by the latch
        #expect(backend.store.joinCallCount == 1, "one server-side attempt")
        first.cancel()
        _ = await first.value
    }
}
```

- [ ] **Step 2: Verify fail, implement.** Stored state in the MAIN body (near `startFailed`; keep it terse — body budget):

```swift
/// Why the most recent create/join attempt failed — ALONGSIDE the payload-free phase
/// (see `EntryFailureReason`). Cleared at the top of every attempt; written immediately
/// before the failure phase with no suspension between.
public private(set) var entryFailureReason: EntryFailureReason?
/// Re-entrancy latch for create/join — the `isEnding` shape (a double-tapped Try-again
/// must not create two server-side rides).
private var isEntering = false
```

In the Task-2 entry extension, `create(route:)` becomes:

```swift
public func create(route inputRoute: Route?) async {
    guard DisplayName.normalized(displayNameProvider()) != nil else {
        phase = .needsDisplayName
        return
    }
    guard !isEntering else { return }
    isEntering = true
    defer { isEntering = false }
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

`join(code:)`'s entry/failure section becomes (success body + three-way route decode unchanged):

```swift
    guard !isEntering else { return }
    isEntering = true
    defer { isEntering = false }
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

(`phase = .idle` is safe against the scenePhase reconcile: `lifecyclePhase` returns nil for `.idle`, so `reconcileFromStatus` guards out — verified at the gate.)

- [ ] **Step 3:** New tests green, then the FULL suite. If an existing lifecycle test observed a phase sequence this changes, read the failure before adjusting either side.
- [ ] **Step 4:** `swiftlint --strict` (body budget check), then `git commit -am "feat(roh-231): session entry attempts — reason alongside phase, bounded, re-entrancy-latched"`

---

### Task 5: Live backend maps reachability failures (app target)

**Files:**
- Modify: `Aura/Sources/Sync/SupabaseGroupRideBackend.swift`

**Interfaces:**
- Consumes: Task 3's classifier + `GroupRideError.connectionFailed`.
- Produces: `joinRide`/`createRide` distinguish reachability from rejection, and — gate blocker — **rethrow cancellation untouched**, because `withTimeout`'s `CancellationError → TimeoutError` conversion is the only thing standing between "the entry timed out" and the lie "your code is wrong". This mapping is app-target (no test bundle); Task 3's classifier tests + this review-pinned ordering are the coverage — say so in the PR.

- [ ] **Step 1: `joinRide`'s catch chain** (`SupabaseGroupRideBackend.swift:56`) becomes, in this order:

```swift
        } catch is CancellationError {
            // withTimeout cancelled us (entry timeout) or the caller unwound. Rethrow
            // untouched: swallowing this into .joinFailed would defeat the timeout's
            // CancellationError → TimeoutError conversion and misreport a timeout as a
            // rejection ("check your code" over a dead network — ROH-231 gate finding).
            throw CancellationError()
        } catch let error where EntryFailure.isConnectionFailure(error) {
            throw GroupRideError.connectionFailed
        } catch { throw GroupRideError.joinFailed }
```

- [ ] **Step 2: `createRide`** — after the existing `routeTooLarge` catch (keep it first and untouched), add:

```swift
        } catch let error where EntryFailure.isConnectionFailure(error) {
            throw GroupRideError.connectionFailed
        }
```

(`createRide` has no catch-all, so cancellation and server errors already propagate raw — the session classifies them.)

- [ ] **Step 3:** Builder: app builds. Commit — `git commit -am "feat(roh-231): live backend distinguishes reachability from rejection, rethrows cancellation"`

---

### Task 6: `AppRoute.joinRide(seed:)` + `AppRouter.replaceTop(with:)`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`
- Modify: `Aura/Sources/App/AppRouter.swift`
- Modify: `Aura/Sources/AuraApp.swift` (destination switch), `Aura/Sources/Home/HomeView.swift:352` (call site)
- Modify: `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift` — **line 78 uses bare `AppRoute.joinRide` and stops compiling** (gate catch); update it alongside the new test.

**Interfaces:**
- Produces: `case joinRide(seed: String)` (seed participates in `==`/`hash`); `AppRouter.replaceTop(with: AppRoute)` — single-write, no auth gate (the join screen needs none).

- [ ] **Step 1: Failing test** (append to `AppRouteTests.swift`):

```swift
@Test func joinRideSeedParticipatesInIdentity() {
    #expect(AppRoute.joinRide(seed: "AB3KQ9RT") == AppRoute.joinRide(seed: "AB3KQ9RT"))
    #expect(AppRoute.joinRide(seed: "AB3KQ9RT") != AppRoute.joinRide(seed: ""))
}
```

- [ ] **Step 2: Implement.** In `AppRoute`:

```swift
/// The group-ride join-code entry screen, pushed on the nav stack (not a sheet) so it
/// never conflicts with Home's always-present dashboard sheet. `seed` pre-fills the code
/// boxes — "" for a fresh entry, the typed code for a Try-again return (ROH-231).
case joinRide(seed: String)
```

`==`: `case let (.joinRide(a), .joinRide(b)): return a == b`. `hash`: `case let .joinRide(seed): hasher.combine(4); hasher.combine(seed)`. Fix every reference the compiler flags: `AppRouteTests.swift:78`; `HomeView.swift:352` → `.joinRide(seed: "")`; `AuraApp.swift`'s destination → `case let .joinRide(seed): GroupRideJoinView(seed: seed)` (keep `.navigationBarBackButtonHidden(true)` + comment). Then `grep -rn "\.joinRide" Aura/ AuraCore/ --include="*.swift"` for stragglers.

In `AppRouter` (below `replaceTopWithGroupRide`):

```swift
/// Single-write top replacement for transient screens with no auth gate (the join screen).
/// Same rationale as `replaceTopWithGroupRide`: never dismiss() + push in one tick.
func replaceTop(with route: AppRoute) {
    if path.isEmpty { path = [route] } else { path[path.count - 1] = route }
}
```

- [ ] **Step 3:** `swift test --filter AppRouteTests`, both totals, builder-build.
- [ ] **Step 4:** `git commit -am "feat(roh-231): joinRide carries a seed; router gains a plain replaceTop"`

---

### Task 7: Flow surfaces — entry-aware loading, honest failures, exits that work

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupRideFlowView.swift`

**Interfaces:**
- Consumes: `session.entryFailureReason` (Task 4), `router.replaceTop(with:)` + `.joinRide(seed:)` (Task 6), `invokeEntry()` (existing).
- Produces: five `dismissMessage` sites with detail/retry; `.idle` becomes entry-aware loading. Copy note (gate): the spec's approved one-liners are deliberately split into title + detail (em dash → full stop, capitalized detail) — a presentation split of the approved strings, not new copy.

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

- [ ] **Step 2: `.idle` → entry-aware loading:**

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

- [ ] **Step 3: Failure cases** in `otherPhaseContent` (with `private var connectionFailed: Bool { session.entryFailureReason == .connectionFailed }`):

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
            // .joinFailed is only written by join(code:), so the entry is always .join
            // (gate: v1's else-branch here was dead code).
            if case let .join(code) = entry {
                router.replaceTop(with: .joinRide(seed: code.rawValue))
            }
        }
    )
```

The corrupt-payload branch in `ridingContainer` gains the same `detail:` line as `routeUnavailable`. `endedLobbySurface` is untouched. That accounts for all five `dismissMessage` sites.

- [ ] **Step 4: Builder-build; sim-verify Tier 1** on `D221B3C5-13DE-482F-B0FD-017B305EC31B`: (a) wrong-but-well-formed code vs the live backend → rejected surface, Try again returns to the join screen with the code in the boxes; (b) network-off sim → connection surface; (c) create → "Setting up your crew ride…". Screenshots. Note for the PR (gate finding, accepted): Try-again is uncapped against the server's 10-joins/min rate limiter, whose generic raise lands as the (cause-agnostic) rejected copy — stated for the PO gate, no counter shipped.
- [ ] **Step 5:** `git commit -am "feat(roh-231): flow surfaces — entry-aware loading, honest failure copy, Try again exits"`

---

### Task 8: Name-prompt framing (`DisplayNameEditor.contextLine`)

**Files:**
- Modify: `Aura/Sources/GroupRide/DisplayNameEditor.swift`
- Modify: `Aura/Sources/GroupRide/GroupRideFlowView.swift` (call site)

**Interfaces:**
- Produces: `var contextLine: String? = nil` declared **immediately BEFORE `onSaved`** (gate blocker: v1 said "after" with an inverted SE-0286 rationale and did not compile — a trailing closure cannot bind a parameter that precedes an explicitly-passed label; with `store, contextLine, onSaved, dismissesOnSave`, the call `DisplayNameEditor(store:contextLine:) { … }` binds the closure to `onSaved` because everything after it is defaulted, and Settings' `DisplayNameEditor(store:dismissesOnSave:)` skips both defaulted middles).

- [ ] **Step 1:** In `DisplayNameEditor`, between `store` and `onSaved`:

```swift
    /// One quiet line above the field saying WHY a name is being asked for. The group-ride
    /// gate passes it; Settings (already titled "Crew name") leaves it nil. Declared BEFORE
    /// `onSaved` so trailing-closure call sites keep resolving.
    var contextLine: String? = nil
```

Render at the top of the body's `VStack`, before `fieldCard`:

```swift
            if let contextLine {
                Text(contextLine)
                    .font(.subheadline)
                    .foregroundStyle(AuraTheme.textSecondary)
            }
```

- [ ] **Step 2: Flow call site** (`GroupRideFlowView`, the `.needsDisplayName` case):

```swift
            DisplayNameEditor(store: displayNameStore,
                              contextLine: "Pick a crew name — it's how your crew sees you.") {
                Task { await invokeEntry() }
            }
```

- [ ] **Step 3:** Builder-build (this is the proof Settings' call still resolves — a diff-stat of the Settings folder proves nothing and was cut). Sim: fresh crew name → Start a ride → framed prompt. Screenshot. Add `#Preview("Group gate — framed")` passing the contextLine.
- [ ] **Step 4:** `git commit -am "feat(roh-231): the name prompt says why it's asking"`

---

### Task 9: Link-aware paste parser (`JoinCodePaste`)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/JoinCodePaste.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/JoinCodePasteTests.swift`

(Both reviewers compiled this task's six tests against the real `DeepLink.parse` grammar and passed them — unchanged from v1.)

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

- [ ] **Step 2: Implement:**

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

- [ ] **Step 3:** Green (both totals). `git commit -am "feat(roh-229): pasting the shared link fills the code"`

---

### Task 10: Join screen rebuild

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupRideJoinView.swift`

**Interfaces:**
- Consumes: `JoinCodePaste.extract` (Task 9); `init(seed:)` (already wired to production by Task 6).
- Produces: keyboard-dismissible, Join pinned above the keyboard, caption on disabled state, Dynamic Type capped. Decision 2a: explicit Join stays.

- [ ] **Step 1: Keyboard.** On the hidden `TextField` (after `.autocorrectionDisabled()`): `.submitLabel(.join)`. In `.toolbar`:

```swift
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFocused = false }
            }
```

- [ ] **Step 2: Pin Join.** Delete the `Spacer(minLength:)` + `joinButton` block from the main `VStack` and add `Spacer(minLength: 0)` at its end. Attach the inset **AFTER** `.contentShape(Rectangle()).onTapGesture { … }` (gate finding: attached before, the caption strip joins the tap-to-focus target and re-raises the keyboard):

```swift
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
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

NO ScrollView (spec §5).

- [ ] **Step 3: Paste + cap.** Paste button: `rawInput = JoinCodePaste.extract(clipboardString)`. Outer view: `.dynamicTypeSize(...DynamicTypeSize.accessibility1)`. Boxes stay `metricCockpit(20, relativeTo: .title3)`.

- [ ] **Step 4: Doc comment** — delete the "**Known gap, deferred:**" paragraph; note the toolbar-Done fix (background tap still focuses, never dismisses).

- [ ] **Step 5: Sim-verify (evidence REQUIRED keyboard-UP on an SE-class screen).** `xcrun simctl list devices | grep -i SE`; if absent, `xcrun simctl create "Aura SE" "iPhone SE (3rd generation)"` (fall back to the smallest available device type and say so in the PR). Keyboard-up: Join AND caption visible above the keyboard. On iPhone 17: empty/partial/valid, Done dismisses, link paste fills. Screenshots.
- [ ] **Step 6:** `git commit -am "feat(roh-229): join screen — pinned Join, keyboard Done, caption, link-aware paste"`

---

### Task 11: `LobbyCrewLabel` (predicate + count, package)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/LobbyCrewLabel.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/LobbyCrewLabelTests.swift`

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

- [ ] **Step 2: Implement:**

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

- [ ] **Step 3:** Green (both totals). `git commit -am "feat(roh-230): lobby crew label — the count excludes self, waiting is reachable"`

---

### Task 12: One code voice + role-aware empty state (components + adoption)

**Files:**
- Create: `Aura/Sources/GroupRide/JoinCodeText.swift`
- Create: `Aura/Sources/GroupRide/CrewEmptyState.swift`
- Modify: `Aura/Sources/GroupRide/GroupLobbyView.swift`
- Modify: `Aura/Sources/GroupRide/GroupRosterSheet.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView+Cockpit.swift:84` (call site gains `isHost:`)

**Interfaces:**
- Produces: `JoinCodeText(code:size:textStyle:color:)`; `CrewEmptyState(variant:)` with `.lobby` / `.rosterHost(code:)` / `.rosterGuest`; `GroupRosterSheet.init` gains `isHost: Bool = true`.
- **Reconciliation decision (gate finding):** v1 selected the roster variant by `joinCode` presence, but `joinCode` is non-nil for EVERY group rider (set on both create and join paths), so `.rosterGuest` was production-dead — as is today's equivalent branch. The selector is now **role**: the host variant carries the code + share hint; a guest sees the guest line. This realizes spec §6's three-variant intent with a reachable third variant.

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

    /// The one tracking token — never a second `.tracking`/`.kerning` on a code.
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

- [ ] **Step 2: `CrewEmptyState.swift`.** ALL of the component's own spacing lives here; adopters add background/card chrome only (gate finding: v1 double-stacked the vertical padding):

```swift
import SwiftUI
import AuraCore

/// The shared crew waiting state (ROH-230) — three variants, one voice, selected by ROLE
/// at the roster (every group rider has a code, so code-presence selects nothing). The
/// lobby variant shows no code (the code card sits directly above it).
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

- [ ] **Step 3: Lobby adoption.** Eyebrow → `Text("Join code").font(.caption.weight(.semibold)).foregroundStyle(AuraTheme.textSecondary)` (sentence case, NO tracking); code text → `JoinCodeText(code: codeText)`; roster header → `Text(LobbyCrewLabel.text(totalRows: rows.count))`; branch → `if LobbyCrewLabel.isWaiting(totalRows: rows.count)`. `emptyRosterState` becomes ONLY the card chrome around the component (its old frame/padding pair is now inside the component — do not keep both):

```swift
    private var emptyRosterState: some View {
        CrewEmptyState(variant: .lobby)
            .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
    }
```

- [ ] **Step 4: Roster adoption.** `GroupRosterSheet.init` gains `isHost: Bool = true` (stored `let`); `emptyState` becomes:

```swift
    private var emptyState: some View {
        CrewEmptyState(variant: (isHost && joinCode != nil) ? .rosterHost(code: joinCode!) : .rosterGuest)
    }
```

Delete the dead monospaced/kerned code rendering. Call site `NavigateHUDView+Cockpit.swift:84` passes `isHost: groupSession.isHost`. Fix the preview helper's `joinCode: "MX4T7Q"` → `"MX4T7Q2A"` (8 chars, valid charset — gate catch) and add one guest preview (`isHost: false`) so the third variant has evidence.

- [ ] **Step 5:** `cd Aura && xcodegen`; builder-build; sim: host lobby with nobody joined → "Join code" card + "Crew" header + reachable empty state. Grep gate: `grep -rn "JOIN CODE\|kerning" Aura/Sources/GroupRide/` → nothing. Screenshots.
- [ ] **Step 6:** `git commit -am "feat(roh-230): one join-code voice, role-aware empty state, reachable lobby waiting"`

---

### Task 13: Widen the rider palette to eight

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/RiderPaletteTests.swift`

**Gate measurements that reshaped this task:** both reviewers independently ran the suite's ΔE math. v1's salmon `#E0876B` **hard-fails** deuteranopia vs gold (ΔE 4.3, floor 12) — a third warm hue cannot clear the collapsed red-green axis, which is why the extra hues must be cool/neutral. Periwinkle `#8E9BE0` and sage `#A3C7A3` pass every gate against the shipped five (tightest: periwinkle–violet 25.5/20.2; sage–violet deuter 13.6; sage–mint 33.3). The pink-clearance gate passes for the existing five (min 48.1).

- [ ] **Step 1: Tighten the tests:**

```swift
@Test func eightRiderHues() {
    #expect(AuraPalette.riderHues.count == 8)   // ROH-114 §D3.3's widening decision
}

/// New hues approach reserved-token space; pink is the destructive token, so identity must
/// stay perceptually clear of it exactly as it does of mint (route) and amber (warning).
@Test func riderHuesStayPerceptuallyClearOfPink() {
    for h in AuraPalette.riderHues {
        #expect(deltaE(h, AuraPalette.pink) >= 15)
    }
}
```

- [ ] **Step 2:** Run — `eightRiderHues` fails (count 5); the pink gate must pass for the existing five (it measures ≥ 48 — if it doesn't, STOP and surface it).

- [ ] **Step 3: Add three hues** — two measured-passing candidates plus one cool/neutral third:

```swift
        RGBColor(red: 0.557, green: 0.608, blue: 0.878),  // periwinkle #8E9BE0 (cool, mid)
        RGBColor(red: 0.640, green: 0.780, blue: 0.640),  // sage    #A3C7A3  (green-grey, light)
        RGBColor(red: 0.722, green: 0.659, blue: 0.847)   // lavender #B8A8D8 (cool-neutral, light) — CANDIDATE
```

The lavender is the one open slot: it must clear **violet** (`#B07AD0`) at ΔE ≥ 20 normal / ≥ 12 deuteranopia and periwinkle likewise — tune it (or swap to a light blue-grey in the `#9FB8C9` region) within at most **four** iterations of `swift test --filter RiderPaletteTests`. Never re-tune periwinkle or sage against the shipped five (they pass), and never add a third warm hue (the deuteranopia axis is why). If four iterations don't produce a green 8-hue set, STOP and surface to the PO — do not silently ship 7 (spec §4 pins 8 per ROH-114). Update the array's doc comment: count is 8; the additions are all cool/neutral because deuteranopia collapses the warm axis, which already carries its two distinguishable lightness slots (rust, gold).

- [ ] **Step 4:** Full suite (both totals). `git commit -am "feat(roh-228): rider palette widens to eight under the full CVD/WCAG regime"`

---

### Task 14: `PeerPalette.assign` learns `reserved:`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/GroupRide/PeerPalette.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/GroupRide/PeerPaletteTests.swift`

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

- [ ] **Step 2: Implement** — signature gains `reserved: Set<Int> = []`; `var taken = Set<Int>()` becomes `var taken = reserved`. Extend the doc comment: the widening to 8 changed `stableHash % paletteCount`, so "a rider keeps their colour across rides" **broke once** at that update; `reserved:` exists for `RiderColorLatch` — the latch is the session authority, `assign` is its first-assignment step only.

- [ ] **Step 3:** Green (both totals). `git commit -am "feat(roh-228): assign de-collides against latched indices"`

---

### Task 15: `RiderColorLatch`

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/RiderColorLatch.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/RiderColorLatchTests.swift`

**Placement note (stated divergence):** spec §4 says "in AuraKit"; the latch lives in **AuraCore** because it consumes `PeerPalette` (AuraCore) and is pure value logic — the session-ownership requirement the spec actually cares about is Task 16's.

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
        #expect(latch.colorIndex(for: b) != latch.colorIndex(for: c), "the released slot is reusable")
    }

    @Test func lookupMissReturnsNil() {
        let latch = RiderColorLatch(paletteCount: 8)
        #expect(latch.colorIndex(for: a) == nil)
    }
}
```

- [ ] **Step 2: Implement:**

```swift
import Foundation

/// The one colour authority for a session's riders (ROH-114 §D3.3, adopted by ROH-228).
/// First assignment LATCHES: a rider's hue never changes while they remain in the session —
/// the input-set-sensitive `PeerPalette.assign` alone reshuffles ~39% of existing riders per
/// membership change, which is the shipped map bug this replaces. Input is peers-minus-self
/// (self consumes no hue: white = me). A peer missing from an update keeps their hue
/// (staleness is not departure); `release` fires only on explicit `.memberLeft`, so a
/// force-quit rider never releases — bounded, and stated rather than hidden. The one stated
/// exception to "never changes": a rider who explicitly leaves and is later resurrected by a
/// stale `.position` re-latches a fresh hue — `.memberLeft` is authoritative departure.
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

- [ ] **Step 3:** Green (both totals). `git commit -am "feat(roh-228): RiderColorLatch — hues latch on first assignment"`

---

### Task 16: `CrewIdentity` + the session's single snapshot writer

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/CrewIdentity.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GroupRide/CrewIdentityTests.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Create: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideRiderColorTests.swift`

**Interfaces:**
- Produces: `CrewIdentity { names, colors, monograms }` + pure `CrewIdentity.derive(peers:selfUserID:nameMap:colors:)` — ONE derivation for every surface (gate finding: v1 fixed the hue divergence but left the lobby and map computing monograms over DIFFERENT input sets, re-creating for labels the exact disease spec §1.2 diagnosed for colour). `GroupRideSession` gains `public private(set) var crewIdentity: CrewIdentity` and a single private `snapshotPeers(from:)` through which EVERY `peers` write flows (gate finding: a grep instruction is not an invariant — one writer is).

- [ ] **Step 1: Failing tests** (`CrewIdentityTests.swift`):

```swift
import Testing
import Foundation
@testable import AuraCore

struct CrewIdentityTests {
    let selfID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
    let maraID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-00000000000A")!
    let miraID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-00000000000B")!

    @Test func selfContributesNothing() {
        let identity = CrewIdentity.derive(
            peers: [RidePeer(userID: selfID, displayName: "Jamie"),
                    RidePeer(userID: maraID, displayName: "Mara")],
            selfUserID: selfID, nameMap: [:], colors: [maraID: 3])
        #expect(identity.names[selfID] == nil)
        #expect(identity.monograms[selfID] == nil)
        #expect(identity.names[maraID] == "Mara")
    }

    /// Monograms widen over the FULL peers-minus-self set — including a coordinate-less
    /// `.awaiting` member — so the map and the lobby can never disagree on a label
    /// (the map previously widened over only the visible set).
    @Test func monogramsWidenOverTheFullPeerSetNotTheVisibleOne() {
        let identity = CrewIdentity.derive(
            peers: [RidePeer(userID: maraID, displayName: "Mara", coordinate: Coordinate(latitude: 1, longitude: 2)),
                    RidePeer(userID: miraID, displayName: "Mira")],   // no coordinate: awaiting
            selfUserID: selfID, nameMap: [:], colors: [:])
        #expect(identity.monograms[maraID] == "MA")
        #expect(identity.monograms[miraID] == "MI")
    }

    @Test func nameMapOverridesThePeerCarriedName() {
        let identity = CrewIdentity.derive(
            peers: [RidePeer(userID: maraID, displayName: "")],
            selfUserID: selfID, nameMap: [maraID: "Mara Chen"], colors: [:])
        #expect(identity.names[maraID] == "Mara Chen")
    }
}
```

- [ ] **Step 2: Implement `CrewIdentity`:**

```swift
import Foundation

/// The single derivation of rider identity for every surface (ROH-228): resolved display
/// names, latched hue indices, and collision-widened monograms — all over peers-minus-self.
/// The lobby and the map LOOK THIS UP; neither may call `RiderMonogram.assign` or
/// `PeerPalette.assign` itself (a shared function with different input sets is the disease
/// this bundle cures, spec §1.2 — first for hue, and at the plan gate for labels too).
public struct CrewIdentity: Equatable, Sendable {
    public var names: [UUID: String]
    public var colors: [UUID: Int]
    public var monograms: [UUID: String]

    public static let empty = CrewIdentity(names: [:], colors: [:], monograms: [:])

    public init(names: [UUID: String], colors: [UUID: Int], monograms: [UUID: String]) {
        self.names = names
        self.colors = colors
        self.monograms = monograms
    }

    public static func derive(peers: [RidePeer], selfUserID: UUID?,
                              nameMap: [UUID: String], colors: [UUID: Int]) -> CrewIdentity {
        let others = peers.filter { $0.userID != selfUserID }
        let names = Dictionary(uniqueKeysWithValues: others.map {
            ($0.userID, DisplayName.forDisplay(nameMap[$0.userID] ?? $0.displayName))
        })
        return CrewIdentity(names: names, colors: colors, monograms: RiderMonogram.assign(names: names))
    }
}
```

- [ ] **Step 3: Session tests** (`GroupRideRiderColorTests.swift`):

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
        #expect(session.crewIdentity.colors[peerA] != nil)
        #expect(session.crewIdentity.colors[session.selfUserID!] == nil, "white = me: self holds no hue")
    }

    @Test func aHueSurvivesMembershipChange() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        let hue = session.crewIdentity.colors[peerA]
        await session.ingest(position(peerB))
        #expect(session.crewIdentity.colors[peerA] == hue)
    }

    @Test func memberLeftReleasesTheHue() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        await session.ingest(.memberLeft(peerA))
        #expect(session.crewIdentity.colors[peerA] == nil)
    }

    @Test func identityCoversEveryNonSelfPeerInTheSnapshot() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        await session.ingest(position(peerB))
        for peer in session.peers where peer.userID != session.selfUserID {
            #expect(session.crewIdentity.colors[peer.userID] != nil,
                    "one writer: no peer can appear without a latched hue")
        }
    }
}
```

- [ ] **Step 4: Implement on the session.** Stored (main body, terse):

```swift
/// Latched hues + resolved names + monograms, peers-minus-self (ROH-228). Surfaces LOOK
/// UP; the single writer is `snapshotPeers(from:)`, so no peer can be visible without
/// identity. `.memberLeft` releases the hue (see `RiderColorLatch`'s doc for the one
/// stated exception).
public private(set) var crewIdentity: CrewIdentity = .empty
private var colorLatch = RiderColorLatch(paletteCount: AuraPalette.riderHues.count)
```

New method (in the lobby-poll extension, renamed `// MARK: - Lobby roster poll & crew snapshot`):

```swift
    /// THE one writer for `peers` — keeps the latch and `crewIdentity` atomic with the
    /// snapshot (a fifth ad-hoc `peers =` write was the failure mode the plan gate flagged).
    func snapshotPeers(from session: RideSession) {
        peers = session.peers
        colorLatch.latch(peerIDs: peers.map(\.userID).filter { $0 != selfUserID })
        crewIdentity = CrewIdentity.derive(peers: peers, selfUserID: selfUserID,
                                           nameMap: nameMap, colors: colorLatch.assignments)
    }
```

Replace **all four** `peers = session.peers` assignments (`beginLiveSession`, `tick`, `ingest`, `mergeLobbyRoster`) with `snapshotPeers(from: session)`. In `ingest`'s `.memberLeft` case add `colorLatch.release(id)` before the toast append (the subsequent `session.ingest` removes the peer, then the snapshot refreshes). The latch is NOT reset in `teardownLive` (a fresh `GroupRideSession` per entry starts fresh anyway).

- [ ] **Step 5:** All new tests green, full suite (both totals), `swiftlint --strict` (body/file budgets — apply the Task 2 disable header if the file crossed 500).
- [ ] **Step 6:** `git commit -am "feat(roh-228): CrewIdentity — one derivation, one snapshot writer"`

---

### Task 17: Map driver reads `CrewIdentity`

**Files:**
- Modify: `Aura/Sources/GroupRide/PeerAnnotations.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift:415-423` (`syncPeers` — two `updateSet` calls, **net-zero lines**: the file is at 498/500)

**Interfaces:**
- Consumes: `session.crewIdentity` (Task 16).
- Produces: `updateSet(peers:selfUserID:identity:reduceMotion:now:)` — 5 parameters (the bundle replaces `nameMap`, keeping `function_parameter_count` ≤ 5, gate blocker), and the driver's own `PeerPalette.assign` + `RiderMonogram.assign` calls are DELETED (the shipped mid-ride reshuffle dies here, and map monograms now agree with the lobby's by construction).

- [ ] **Step 1: Driver.** `updateSet` signature: replace `nameMap: [UUID: String]` with `identity: CrewIdentity`. Body: replace the three derivation lines with:

```swift
        displayNames = Dictionary(uniqueKeysWithValues:
            visible.map { ($0.userID, identity.names[$0.userID] ?? $0.displayName) })
        // Snapshot-atomic lookups (ROH-228): the session's one writer guarantees every
        // non-self peer has an entry, so these defaults are compile-time appeasement,
        // not a second derivation path — never re-introduce assign() here.
        colorIndex = Dictionary(uniqueKeysWithValues:
            visible.map { ($0.userID, identity.colors[$0.userID] ?? 0) })
        monograms = Dictionary(uniqueKeysWithValues:
            visible.map { ($0.userID, identity.monograms[$0.userID] ?? "?") })
```

Remove the now-unused `PeerPalette`/`RiderMonogram` references from this file.

- [ ] **Step 2: Call sites** (`syncPeers`, net-zero): nil branch passes `identity: .empty`; live branch passes `identity: groupSession.crewIdentity` (each replaces the old `nameMap:` argument in place).

- [ ] **Step 3: Preview.** Give the file's `#Preview` frozen `UUID(uuidString:)!` ids and a frozen `CrewIdentity` (names for all four, `colors: [mara: 0, mira: 1, devon: 2, sam: 3]`, monograms from those names) in place of the old `nameMap: [:]` arguments.

- [ ] **Step 4:** Builder-build; `wc -l Aura/Sources/Ride/NavigateHUDView.swift` ≤ 500; preview screenshot (four distinctly-hued dots). The reshuffle fix itself is Tier 2 (Task 20's issue).
- [ ] **Step 5:** `git commit -am "fix(roh-228): map peer identity comes from the session bundle — no more mid-ride reshuffle"`

---

### Task 18: Lobby identity rows (`CrewMonogram`, white = me, You/Host markers)

**Files:**
- Create: `Aura/Sources/GroupRide/CrewMonogram.swift`
- Modify: `Aura/Sources/GroupRide/GroupLobbyView.swift` (rows + row view)

**Interfaces:**
- Consumes: `session.crewIdentity`, `session.hostID`, board reference `2026-08-31-crew-identity-board.svg`.
- Produces: identity rows; self = white disc + real name + "You" marker; host marker. `CrewMonogram` takes an EXPLICIT `isSelf` (gate finding: v1 encoded self as `colorIndex == nil`, so an identity-lookup miss would have rendered a peer as "me").

- [ ] **Step 1: `CrewMonogram.swift`:**

```swift
import SwiftUI
import AuraCore

/// A rider's identity disc (ROH-228, gate-1 board): latched hue + monogram for a peer;
/// WHITE for self — "white = me" is the puck grammar, and the rider marker is never
/// accent-mint. `isSelf` is explicit so a lookup miss can never masquerade as self.
struct CrewMonogram: View {
    let isSelf: Bool
    let colorIndex: Int
    let label: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelf ? AuraTheme.textPrimary : AuraTheme.riderColor(colorIndex))
                .frame(width: size, height: size)
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isSelf ? AuraTheme.background : AuraTheme.riderInk(colorIndex))
        }
        .accessibilityHidden(true)   // the row's combined label carries the name
    }
}
```

- [ ] **Step 2: Rebuild the lobby rows.** (Gate blocker folded in: `DisplayName.forDisplay` NEVER returns "" — it falls back to "Rider" — so the resolved-check is `DisplayName.normalized(raw) == nil`, and the marker is driven by a real `showsSelfMarker` flag, not a string compare.)

```swift
private struct LobbyRosterRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let isSelf: Bool
    let isHost: Bool
    let colorIndex: Int
    let monogram: String
    let showsSelfMarker: Bool
}
```

```swift
    private var rows: [LobbyRosterRow] {
        let identity = session.crewIdentity
        return session.peers.map { peer in
            let isSelf = peer.userID == session.selfUserID
            let raw = session.nameMap[peer.userID] ?? peer.displayName
            let unresolved = DisplayName.normalized(raw) == nil
            let name = (isSelf && unresolved) ? "You" : DisplayName.forDisplay(raw)
            return LobbyRosterRow(
                id: peer.userID, name: name, isSelf: isSelf,
                isHost: peer.userID == session.hostID,
                colorIndex: identity.colors[peer.userID] ?? 0,
                monogram: isSelf ? String(name.prefix(1)).uppercased()
                                 : (identity.monograms[peer.userID] ?? "?"),
                showsSelfMarker: isSelf && !unresolved)
        }
    }
```

`LobbyRosterRowView` body:

```swift
    var body: some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            CrewMonogram(isSelf: row.isSelf, colorIndex: row.colorIndex, label: row.monogram)
            Text(row.name)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                .lineLimit(1)
            if row.showsSelfMarker { marker("You") }
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

(The old always-accent disc dies here — the third monogram implementation ignoring the rider palette.)

- [ ] **Step 3:** `cd Aura && xcodegen`; builder-build. The lobby previews drive real sessions and now show hued discs + markers. Sim-verify against the board SVG side-by-side. Screenshots.
- [ ] **Step 4:** `git commit -am "feat(roh-228): lobby identity rows — latched hues, white = me, You/Host markers"`

---

### Task 19: Roster "You YOU" fix

**Files:**
- Modify: `AuraCore/Sources/AuraCore/GroupRide/GroupRosterViewData.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/GroupRide/GroupRosterViewDataTests.swift`
- Modify: `Aura/Sources/GroupRide/GroupRosterSheet.swift` (marker guard + previews)

**Interfaces:**
- Produces: the self row shows the real display name when resolved; `RosterRow` gains `nameResolved: Bool = true` (defaulted — the ~10 existing preview/test inits keep compiling); the view's marker guard uses it. Gate blockers folded in: `forDisplay` falls back to "Rider" (the existing `nameMapOverridesBlank_elseRider` test pins it), so the predicate is `normalized == nil`, and without the flag the fallback would render "Rider YOU".

- [ ] **Step 1: Failing tests** (append):

```swift
@Test func theSelfRowShowsTheRealNameWhenTheRosterResolvesIt() {
    let selfID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!
    let rows = GroupRosterViewData.rows(peers: [], nameMap: [selfID: "Jamie Rivera"],
                                        selfUserID: selfID, selfProgress: 0, isImperial: true)
    #expect(rows[0].name == "Jamie Rivera")
    #expect(rows[0].isSelf)
    #expect(rows[0].nameResolved)
}

@Test func anUnresolvedSelfNameFallsBackToYouWithNoMarker() {
    let selfID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000002")!
    let rows = GroupRosterViewData.rows(peers: [], nameMap: [:],
                                        selfUserID: selfID, selfProgress: 0, isImperial: true)
    #expect(rows[0].name == "You")
    #expect(!rows[0].nameResolved, "the view suppresses the marker so it can't read You YOU")
}
```

- [ ] **Step 2: Implement.** `RosterRow` gains `public let nameResolved: Bool` with `nameResolved: Bool = true` appended to the init. In `rows`, the name lines become:

```swift
            let raw = nameMap[peer.userID] ?? peer.displayName
            let resolved = DisplayName.normalized(raw) != nil
            let name = (isSelf && !resolved) ? Self.selfLabel : DisplayName.forDisplay(raw)
```

(make `selfLabel` `public static`), and the constructed row passes `nameResolved: !isSelf || resolved`. In `RosterRowView`, the marker becomes:

```swift
            if row.isSelf && row.nameResolved {
                Text("YOU") // existing style, unchanged
```

- [ ] **Step 3: Previews** (gate finding: all six used `name: "You"` and would demo the fallback, not the fix). Change every self row to `RosterRow(id: …, name: "Jamie Rivera", isSelf: true, status: .riding, distanceLabel: nil)` and add ONE fallback preview row (`name: "You", …, nameResolved: false`) so both states have evidence.

- [ ] **Step 4:** Green (both totals — the existing `nameMapOverridesBlank_elseRider` must still pass untouched), builder-build, sim screenshot of the mid-ride roster.
- [ ] **Step 5:** `git commit -am "fix(roh-228): the roster's self row is a name, not You YOU"`

---

### Task 20: Slice close — gates, evidence, PR, review, board

- [ ] **Step 1: Full local gate.** Repo root `swiftlint --strict`; `cd AuraCore && swift test` (both totals); builder clean app build.
- [ ] **Step 2: Whole-slice before/after evidence set** (PO gate): join screen (empty / partial / valid / keyboard-up SE / caption), lobby (waiting / filled with hued rows + markers), roster (named self row, host + guest empty states), flow (both loading copies, rejected, connection, framed name prompt), map preview (hued dots). Pair with audit "befores" where they exist.
- [ ] **Step 3: Push + PR** to `main`, body stating: Tier 1 evidence inline; **Tier 2 queued** (A0 two-phone fill; per-device hue stability across a mid-ride join); no CI path exercises the poll against a real second device; **stated residuals** — (a) a client-side entry timeout after a server-side commit leaves a ghost `.awaiting` member holding a cap slot until the ride ends (Try-again's idempotent re-join self-heals the common path), (b) Try-again is uncapped against the 10-joins/min limiter, whose generic raise lands as the cause-agnostic rejected copy.
- [ ] **Step 4: Whole-branch review** on the most capable model (Agent-tool-less reviewer); adjudicate before merge.
- [ ] **Step 5: PO gate — STOP AND WAIT** for sign-off on the before/after set before merging.
- [ ] **Step 6: Board.** Create the Tier-2 Verification issue (two-phone: lobby fills within one poll interval; mid-ride joiner's hue stable + map/lobby consistent on one device; ghost-member check after a forced entry timeout) appended to the two-phone queue; walk ROH-227/228/229/230/231 through In Review → Done as the PR merges (revert premature Linear auto-completion); ROH-225 stays open until the Tier-2 pass lands or is explicitly waived.

---

## Reconciliation log (v2, 2026-09-01)

Two independent reviewers (skeptic, architecture — refuting mandates, no shared context) reviewed v1; every finding was adjudicated. v1 is dead. The load-bearing adjudications:

1. **Stale-base blocker (arch):** identity-carriers had already merged to main (PR #140); v1's file-boundary premise and Task-17 rebase check were void, and Task 13 would have hit an `AuraPalette` conflict four tasks before the check. → main merged during reconciliation (`f4c5768`), Task 0 verifies the baseline, all coordination language deleted.
2. **Lint ceilings, measured (both):** `GroupRideSession` body 232/250 — v1's Tasks 2/4/16 blew `type_body_length` at Task 2 and `file_length` (500) by the end. → Task 2 Step 1 relocates the entry/start methods to a same-file extension first (End/Leave precedent), new methods live in extensions, and a documented `file_length` disable header is specified if needed. `updateSet` at 6 params blew `function_parameter_count` → the `CrewIdentity` bundle keeps it at 5.
3. **`forDisplay` never returns "" (both, independently):** v1's `resolved.isEmpty` guard was unreachable; the "You YOU" fix would have shipped "Rider YOU" and its own test could not pass. → predicate is `DisplayName.normalized(raw) == nil`; `RosterRow.nameResolved` (defaulted) drives the marker; the six previews that demoed the fallback now demo the fix.
4. **Cancellation-eating catch-all (arch):** v1's Task 5 rewrote `CancellationError` to `.joinFailed`, defeating `withTimeout`'s TimeoutError conversion — a timed-out join would say "check your code". → `catch is CancellationError` rethrow first; classifier walks one `NSUnderlyingErrorKey` level for wrapped auth/transport errors; a classifier test pins cancellation ≠ connection.
5. **Poll permadeath (both, independently):** v1 started the poll only from `beginLiveSession` (one-shot latch); the phantom-start round trip an existing lifecycle test already walks (`.rideStarted` → authoritative reconcile back to `.lobby`) killed A0 silently. → the poll restarts on every `.lobby` edge (`applyLifecyclePhase`), with a dedicated regression test.
6. **One clock per meaning (both):** sharing the injected `sleep` between `withTimeout` timers and the poll made `end()`'s timer-cancellation broadcast-wake the poll and race the spy read; the edge-triggered gate also lost a release racing task startup 200/200. → separate `pollSleep` seam; level-triggered, cancellation-aware `SleepGate`; positive-control assertions (rosterCallCount) so the idempotence and stop tests cannot pass vacuously.
7. **Salmon fails deuteranopia by 3× (both, measured):** ΔE 4.3 vs gold against a floor of 12 — a third warm hue cannot exist under the CVD gates; v1's escape hatch pointed at sage, which passes everything. → candidates are periwinkle + sage (measured passing) + one cool/neutral slot with a four-iteration budget and a stop-and-ask-PO rule; never ship 7 silently.
8. **Two-write invariant → one writer (arch):** "call refreshRiderColors after every `peers =`" was a grep instruction, and the driver's hash fallback could visibly flip a dot's hue when the latch later disagreed. → `snapshotPeers(from:)` is the single `peers` writer keeping latch + `CrewIdentity` atomic; the driver's defaults are unreachable appeasement, with `assign()` deleted from it (also resolving v1's self-contradiction with "nothing new calls assign").
9. **Monogram divergence (skeptic):** the map widened monograms over the visible (coordinate-holding) set, the lobby over all peers — §10.2's "same monogram on map and lobby" was not delivered for labels. → `CrewIdentity.derive` is the one derivation over peers-minus-self; the driver consumes it.
10. **Dead guest variant (skeptic):** `joinCode` is non-nil for every group rider, so code-presence selected `.rosterGuest` never (today's equivalent branch is equally dead). → role-based selector (`isHost:` on `GroupRosterSheet`), realizing the spec's three-variant intent with a reachable third variant.
11. **`contextLine` placement (skeptic, compiled):** v1's "after `onSaved`" did not compile — the SE-0286 rationale was inverted. → declared before `onSaved`; the diff-stat "proof" of Settings safety was theater and is cut (the build is the proof).
12. **Re-entrancy + ghosts (arch):** create/join had no latch where `finishRide` has `isEnding` — a double-tapped Try-again could create two rides and bind the live layer to the orphan; and a timeout-after-commit join leaves a visible ghost `.awaiting` member (visible precisely because A0 now works). → `isEntering` latch with tests (`joinCallCount` spy); the ghost residual is documented in Task 4, the PR, and the Tier-2 issue (Try-again's idempotent re-join self-heals; no client-side fix exists without the rideID).
13. **Smaller fixes:** `AppRouteTests:78` named; the dead `.joinFailed` else-branch removed with a comment; `safeAreaInset` after the tap gesture (caption strip must not re-focus); `CrewEmptyState` owns its padding (no double-stack); preview join code fixed to 8 valid chars; the phase-reset-to-`.idle` gained an observable in-flight test; the title/detail copy split is declared as a deliberate re-punctuation of approved strings; `RiderColorLatch`'s AuraCore placement is a stated divergence from spec §4's "AuraKit" wording; the leave-then-stale-position re-latch exception is documented on the latch.
