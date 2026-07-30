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

    /// Smallest gap between pushed stat updates. GPS samples and the half-second ticker
    /// arrive far faster than a glanceable surface needs; we coalesce them to this cadence
    /// (a new turn instruction bypasses it — see `update`).
    private let minInterval: TimeInterval = 4
    /// How far ahead to mark content stale. If the app is killed mid-ride the system flips
    /// `context.isStale` after this, and the widget dims the now-frozen stats while the
    /// elapsed clock — wall-clock from `startedAt` — keeps ticking on its own.
    private let staleInterval: TimeInterval = 90

    private var activity: Activity<RideActivityAttributes>?
    private var lastState = RideActivityAttributes.ContentState()
    private var lastPush: Date?
    private var lastInstruction: String?

    /// Begins a Live Activity for a ride, if the rider has them enabled. Best-effort:
    /// a failure here never affects the ride itself.
    func start(mode: RideActivityMode,
               startedAt: Date,
               units: DistanceUnits,
               destinationName: String?) {
        // Honor the user/system setting — never force-enable.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Defensive: clear any activity a previous ride somehow left running.
        end()

        let attributes = RideActivityAttributes(
            mode: mode, startedAt: startedAt, units: units, destinationName: destinationName)
        let state = RideActivityAttributes.ContentState(
            payload: RideActivityPayload(clock: .running(anchor: startedAt)))
        let content = ActivityContent(state: state,
                                      staleDate: startedAt.addingTimeInterval(staleInterval))
        do {
            activity = try Activity.request(attributes: attributes, content: content)
            lastState = state
            lastPush = startedAt
            lastInstruction = nil
        } catch {
            activity = nil
        }
    }

    /// Pushes the latest ride stats, the next maneuver (in navigate mode), and the active clock.
    /// Throttled: pushes only when at least `minInterval` has elapsed, or immediately when the
    /// turn instruction changes — so the activity reflects a new maneuver right away while
    /// distance/speed churn stays coalesced. Safe to call every tick; a no-op when no
    /// activity is running.
    func update(stats: RideStats,
                currentSpeedMetersPerSecond: Double,
                maneuver: GuidanceUpdate?,
                activeClock: RideActiveClock) {
        guard let activity else { return }

        let instruction = maneuver?.instruction
        let now = Date()
        let turnChanged = instruction != lastInstruction
        let due = lastPush.map { now.timeIntervalSince($0) >= minInterval } ?? true
        guard turnChanged || due else { return }

        lastPush = now
        lastInstruction = instruction

        let payload = RideActivityPayload(
            distanceMeters: stats.distanceMeters,
            speedMetersPerSecond: currentSpeedMetersPerSecond,
            elevationGainMeters: stats.elevationGainMeters,
            turnInstruction: instruction,
            turnDistanceMeters: maneuver?.distanceToManeuverMeters,
            turnGlyphSystemName: ManeuverIcon.symbol(for: maneuver?.maneuver),
            clock: activeClock)
        let state = RideActivityAttributes.ContentState(payload: payload)
        lastState = state

        let content = ActivityContent(state: state,
                                      staleDate: now.addingTimeInterval(staleInterval))
        Task { await activity.update(content) }
    }

    /// Ends the activity immediately so it clears the moment the ride does (the summary
    /// screen takes over). Idempotent — safe to call from every terminal path.
    func end() {
        guard let activity else { return }
        self.activity = nil
        lastPush = nil
        lastInstruction = nil

        let content = ActivityContent(state: lastState, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }
}
