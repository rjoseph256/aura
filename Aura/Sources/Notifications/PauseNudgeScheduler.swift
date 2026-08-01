import UserNotifications
import os
import AuraCore
import AuraKit

/// Posts the forgotten-pause ladder. The app-target shell behind AuraKit's
/// `RideNudgeScheduling`, the analog of `WorkoutWriter` and `RideLiveActivityController`.
///
/// Holds no policy: every offset, identifier and string comes from `PauseNudgePolicy`, which is
/// unit-tested on the host. This type only talks to `UNUserNotificationCenter`.
@MainActor
final class PauseNudgeScheduler: NSObject, RideNudgeScheduling {
    static let shared = PauseNudgeScheduler()

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "app.aura.ios", category: "pause-nudge")

    private override init() { super.init() }

    /// The system prompts once per install and returns the stored answer afterwards, so this is
    /// safe to call at the start of every ride. Requests sound as well as alerts: a silent
    /// banner on a locked phone is invisible to the rider who needs it.
    ///
    /// Fire-and-forget. Nothing waits on the answer, because the only caller is a ride start and
    /// the schedule that eventually uses it happens minutes later at a pause. A pause taken
    /// while the prompt is still open still adds its requests: iOS evaluates authorization at
    /// delivery, so they are dropped on a decline and presented on an accept.
    ///
    /// Skipped entirely under the golden-ride harness, alongside the ambient-location tier
    /// `AuraApp.syncLocationActivity` skips for the same reason: a deterministic ride must not
    /// raise a system prompt. `requestAuthorization` puts a SpringBoard alert over the HUD
    /// seconds into both `RideE2EUITests` methods, and unlike location there is no
    /// `xcrun simctl privacy` service that could pre-grant it on a freshly installed app, so
    /// every tap the test makes afterwards lands on SpringBoard.
    /// `scheduleForgottenPauseNudges` is skipped for the same reason. Until ROH-103 the harness
    /// never paused, so leaving the nudges wired was harmless; the E2E now pauses four times a
    /// run, and a run that aborts mid-pause would leave its requests alive in that simulator to
    /// fire ten to a hundred and twenty minutes later, over whatever is running then.
    func prepareAuthorization() {
        #if DEBUG
        if SimulatedRideConfig.current != nil { return }
        #endif
        Task { [center, log] in
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func scheduleForgottenPauseNudges(startingAt: Date) {
        #if DEBUG
        if SimulatedRideConfig.current != nil { return }
        #endif
        cancelForgottenPauseNudges()
        // Anchored to the tap rather than to now. In practice these are the same instant, since
        // this is called synchronously from `pause()`; the elapsed subtraction only matters if a
        // future caller schedules retrospectively. Which rungs survive that, and what interval
        // each one gets, is `PauseNudgePolicy.pendingRungs` — host-tested, unlike this file.
        let pending = PauseNudgePolicy.pendingRungs(
            elapsedSincePause: Date().timeIntervalSince(startingAt))
        for item in pending {
            let content = UNMutableNotificationContent()
            content.title = item.rung.title
            content.body = item.rung.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: item.rung.identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: item.interval,
                                                           repeats: false))
            center.add(request) { [log] error in
                if let error { log.error("Nudge add failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        // The count, not a bare "scheduled": armed-five and armed-none are the two states worth
        // telling apart in a device log, and the old wording claimed the former for both.
        log.info("Armed \(pending.count, privacy: .public) of \(PauseNudgePolicy.rungs.count, privacy: .public) pause nudges")
    }

    func cancelForgottenPauseNudges() {
        center.removePendingNotificationRequests(withIdentifiers: PauseNudgePolicy.allIdentifiers)
        center.removeDeliveredNotifications(withIdentifiers: PauseNudgePolicy.allIdentifiers)
    }
}

extension PauseNudgeScheduler: UNUserNotificationCenterDelegate {
    /// Without this, iOS shows nothing while the app is active — and a rider paused to read the
    /// map, with the HUD on screen, is exactly that case (ROH-101 P5).
    ///
    /// Scoped to this feature's own identifiers — but scoped in what it *presents*, not in what
    /// it answers for. This is the app-global delegate, so it decides the foreground behaviour
    /// of every notification Aura will ever post, and once a delegate is installed there is no
    /// falling through to a system default. Anything that is not a pause nudge is answered with
    /// `[]`: nothing shown while the app is active.
    ///
    /// That happens to match what an app with no delegate does, so nothing regresses today.
    /// It is still an app-global decision made here: a future UserNotifications client that
    /// wants a foreground banner has to add its identifiers to this method, or it will be
    /// silently suppressed by this line with no error to explain it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        guard PauseNudgePolicy.allIdentifiers.contains(notification.request.identifier) else {
            return []
        }
        return [.banner, .sound]
    }
}
