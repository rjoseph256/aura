// @preconcurrency: this target enables NonisolatedNonsendingByDefault (see
// SWIFT_APPROACHABLE_CONCURRENCY in project.yml); ActivityKit is not built with it. So from
// here its `nonisolated async` members — `update`, `end` — still read as `@concurrent`, and
// handing them the MainActor-isolated, non-Sendable `Activity` below is a region-isolation
// violation. Swift 6.2 does not diagnose it; 6.3 does. The calls themselves are correct —
// driving a Live Activity from the main actor is what Apple's own guidance does. Remove this
// once ActivityKit ships isolation annotations that make the sends provably safe. See ROH-116.
@preconcurrency import ActivityKit
import Foundation
import os
import AuraCore
import AuraKit

/// Thin manager around the in-progress-ride Live Activity. It owns the single
/// `Activity<RideActivityAttributes>` for a ride and keeps ActivityKit out of the
/// SwiftUI HUDs entirely: they call `start` / `update` / `end` and nothing else.
///
/// A singleton, deliberately. The activity's lifetime is tied to the *ride*, not to the
/// HUD view — which SwiftUI tears down when the summary sheet replaces it, potentially
/// before the async `end` has run. Routing every call through one long-lived object
/// guarantees the end always completes and that two rides can never leak two activities.
@MainActor
final class RideLiveActivityController {
    static let shared = RideLiveActivityController()
    private init() {}

    private let log = Logger(subsystem: "app.aura.ios", category: "live-activity")

    private var activity: Activity<RideActivityAttributes>?
    /// The last payload *enqueued*, and when it was decided. Stamped at enqueue, not after the
    /// push lands: `Activity.update` returns on hand-off with no delivery signal, so no
    /// assignment point could mean "what the widget has" — and deferring the stamp would let
    /// every tick inside the in-flight window decide against pre-push state and enqueue again
    /// (spec D5).
    private var lastPayload: RideActivityPayload?
    private var lastPushedAt: Date?
    /// Serializes pushes so they land in the order they were decided. Two racing tasks could
    /// otherwise leave the widget holding a running state after a pause was pushed.
    private var pushChain: Task<Void, Never>?
    /// Ids some path in this process is already ending, so a sweep does not end them a second
    /// time. Both writers matter (ROH-124 spec D2): `end()` nils `activity` synchronously but
    /// performs the ActivityKit end later, after draining `pushChain`, and `endOrphans()` claims
    /// its snapshot before spawning because a cold launch fires two sweeps within milliseconds
    /// and ActivityKit removes an ended activity from `activities` asynchronously.
    private var endingIDs: Set<String> = []

    /// Begins a Live Activity for a ride, if the rider has them enabled. Best-effort:
    /// a failure here never affects the ride itself.
    func start(mode: RideActivityMode,
               startedAt: Date,
               units: DistanceUnits,
               destinationName: String?) {
        // First, so it runs unconditionally (ROH-124 spec D3). Placed after the request instead,
        // it is skipped when the rider has Live Activities turned off and skipped again when the
        // request throws, which leaves the ghost to outlive the whole session in both cases. It
        // does *not* free a slot for the request below: the ends happen in a Task, and this
        // function never suspends.
        endOrphans()
        // Defensive: clear any activity a previous ride somehow left running.
        end()
        // Honor the user/system setting — never force-enable.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = RideActivityAttributes(
            mode: mode, startedAt: startedAt, units: units, destinationName: destinationName)
        let payload = RideActivityPayload(clock: .running(anchor: startedAt))
        let content = ActivityContent(
            state: RideActivityAttributes.ContentState(payload: payload),
            staleDate: startedAt.addingTimeInterval(RideActivityPushPolicy.staleInterval))
        do {
            activity = try Activity.request(attributes: attributes, content: content)
            lastPayload = payload
            lastPushedAt = startedAt
        } catch {
            activity = nil
            lastPayload = nil
            lastPushedAt = nil
        }
    }

    /// Pushes the latest ride stats, maneuver and clock. Whether the push goes out is
    /// `RideActivityPushPolicy`'s decision — pure and host-tested in AuraCore, because this type
    /// imports ActivityKit and no test target can reach it.
    func update(stats: RideStats,
                currentSpeedMetersPerSecond: Double,
                maneuver: GuidanceUpdate?,
                activeClock: RideActiveClock) {
        guard let activity else { return }

        let now = Date()
        let payload = RideActivityPayload(
            distanceMeters: stats.distanceMeters,
            speedMetersPerSecond: currentSpeedMetersPerSecond,
            elevationGainMeters: stats.elevationGainMeters,
            turnInstruction: maneuver?.instruction,
            turnDistanceMeters: maneuver?.distanceToManeuverMeters,
            // Resolve the directional glyph app-side so the widget stays logic-free.
            turnGlyphSystemName: ManeuverIcon.symbol(for: maneuver?.maneuver),
            clock: activeClock
        ).holdingTurn(from: lastPayload)

        guard RideActivityPushPolicy.decide(last: lastPayload, next: payload,
                                            lastPushedAt: lastPushedAt, now: now) == .push else {
            return
        }

        // Inside the .push branch only: a skip must advance nothing (invariant 3).
        lastPayload = payload
        lastPushedAt = now
        enqueue(payload, on: activity)
    }

    /// Chains onto the previous push so updates land in the order they were decided.
    private func enqueue(_ payload: RideActivityPayload,
                         on activity: Activity<RideActivityAttributes>) {
        let previous = pushChain
        pushChain = Task { @MainActor [weak self] in
            await previous?.value
            // Before the send, not after: placed after, this would prevent stale bookkeeping but
            // not the stale push itself, and `start()` ends the old activity and requests the
            // next one in a single turn.
            guard let self, self.activity === activity else { return }
            // Fresh, so a push that waited behind others does not carry a window that has
            // already half elapsed.
            let staleDate = Date().addingTimeInterval(RideActivityPushPolicy.staleInterval)
            await activity.update(
                ActivityContent(state: RideActivityAttributes.ContentState(payload: payload),
                                staleDate: staleDate))
        }
    }

    /// Ends the activity immediately so it clears the moment the ride does (the summary
    /// screen takes over). Idempotent — safe to call from every terminal path.
    func end() {
        guard let activity else { return }
        self.activity = nil
        let final = lastPayload ?? RideActivityPayload(clock: .running(anchor: Date()))
        lastPayload = nil
        lastPushedAt = nil

        let id = activity.id
        endingIDs.insert(id)
        let previous = pushChain
        pushChain = nil
        Task { @MainActor [self] in
            // Released on any exit from this scope. An id left in `endingIDs` is excluded from
            // every later sweep, so this is the one place that must not be forgotten — though it
            // cannot help if an await below never resumes at all. Capturing `self` strongly is
            // deliberate: this is a `static let` singleton that is never deallocated.
            defer { endingIDs.remove(id) }
            // Drain what is already queued, so the end is the last thing the activity sees.
            await previous?.value
            await activity.end(
                ActivityContent(state: RideActivityAttributes.ContentState(payload: final),
                                staleDate: nil),
                dismissalPolicy: .immediate)
        }
    }

    /// Ends every Live Activity this process does not own: what a previous process left behind
    /// when it was killed mid-ride. Nothing else can reach one. `end()` and `update()` are both
    /// gated on the in-memory `activity`, which a fresh singleton has lost, so after a jetsam kill
    /// the ghost outlives every path that could clear it (ROH-124 spec D1).
    ///
    /// **Synchronous up to the point the orphan set is fixed, and that is the entire safety
    /// argument.** The snapshot and the owned-id read happen in one main-actor turn with no
    /// suspension between them, so no ride can start in the gap and the set captured below can
    /// never contain an activity this process owns. Do not add an `await` above `orphans`, and do
    /// not source the owned id from anywhere but `activity?.id`: a ride's `id.uuidString` is a
    /// different value that matches nothing, which would make *every* activity an orphan,
    /// including the one the current ride is using.
    ///
    /// Sequential on purpose, and not because the parallel form fails to compile — it does
    /// compile. There is nothing to gain from ending two dying activities at once, and a
    /// `TaskGroup` would multiply the `sending Activity` pattern ROH-116 was about. The cost is
    /// head-of-line blocking, recorded under "accepted" below.
    func endOrphans() {
        let owned = activity?.id
        let orphans = Activity<RideActivityAttributes>.activities.filter {
            // An allow-list, not a deny-list. `.ended` and `.dismissed` are already on their way
            // out, and `endingIDs.remove` fires when ActivityKit accepts an end rather than when
            // the entry leaves this list, so re-ending one is pointless. `.pending` is a
            // scheduled activity this app never requests; if it ever does, sweeping one before it
            // starts would be a bug, so it is excluded by construction rather than by omission.
            ($0.activityState == .active || $0.activityState == .stale)
                && $0.id != owned && !endingIDs.contains($0.id)
        }
        guard !orphans.isEmpty else { return }
        for orphan in orphans { endingIDs.insert(orphan.id) }
        // The only signal this feature emits. Without it a device pass cannot tell an end that
        // worked from a sweep that found an empty list, which is the failure mode most likely to
        // masquerade as success (ROH-124 verification).
        log.info("Ending \(orphans.count, privacy: .public) orphaned Live Activity(s)")

        Task { @MainActor [self] in
            // Releases every id this sweep claimed, including any the loop never reached. That
            // covers an early exit; it does **not** cover an `await` below that never resumes,
            // because a scope that never exits never runs its `defer`. Accepted: an
            // `Activity.end` that hangs forever strands the rest of this snapshot in `endingIDs`
            // for the life of the process, and those ghosts stay until iOS retires them. The
            // alternative is a per-end timeout, which is more machinery than a hypothetical
            // deserves.
            defer { for orphan in orphans { endingIDs.remove(orphan.id) } }
            for orphan in orphans {
                // The recovered activity still carries the dead process's last state, and Apple's
                // guidance for `end` is to pass a final content update rather than nil.
                await orphan.end(
                    ActivityContent(state: orphan.content.state, staleDate: nil),
                    dismissalPolicy: .immediate)
            }
        }
    }
}
