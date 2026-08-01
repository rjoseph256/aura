// @preconcurrency: this target enables NonisolatedNonsendingByDefault (see
// SWIFT_APPROACHABLE_CONCURRENCY in project.yml); ActivityKit is not built with it. So from
// here its `nonisolated async` members — `update`, `end` — still read as `@concurrent`, and
// handing them the MainActor-isolated, non-Sendable `Activity` below is a region-isolation
// violation. Swift 6.2 does not diagnose it; 6.3 does. The calls themselves are correct —
// driving a Live Activity from the main actor is what Apple's own guidance does. Remove this
// once ActivityKit ships isolation annotations that make the sends provably safe. See ROH-116.
@preconcurrency import ActivityKit
import Foundation
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

    /// Begins a Live Activity for a ride, if the rider has them enabled. Best-effort:
    /// a failure here never affects the ride itself.
    func start(mode: RideActivityMode,
               startedAt: Date,
               units: DistanceUnits,
               destinationName: String?) {
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

        let previous = pushChain
        pushChain = nil
        Task { @MainActor in
            // Drain what is already queued, so the end is the last thing the activity sees.
            await previous?.value
            await activity.end(
                ActivityContent(state: RideActivityAttributes.ContentState(payload: final),
                                staleDate: nil),
                dismissalPolicy: .immediate)
        }
    }
}
