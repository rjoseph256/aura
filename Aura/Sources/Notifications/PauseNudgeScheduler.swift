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
    func prepareAuthorization() {
        Task { [center, log] in
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func scheduleForgottenPauseNudges(startingAt: Date) {
        cancelForgottenPauseNudges()
        let elapsed = max(0, Date().timeIntervalSince(startingAt))
        for rung in PauseNudgePolicy.rungs {
            // Anchor to the tap rather than to now. In practice these are the same instant,
            // since this is called synchronously from `pause()`; the subtraction only matters
            // if a future caller schedules retrospectively.
            let remaining = rung.after - elapsed
            // A non-repeating time-interval trigger only requires a positive interval. The
            // 60-second minimum applies to `repeats: true`, which no rung uses.
            guard remaining > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = rung.title
            content.body = rung.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: rung.identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false))
            center.add(request) { [log] error in
                if let error { log.error("Nudge add failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        log.info("Scheduled pause nudges")
    }

    func cancelForgottenPauseNudges() {
        center.removePendingNotificationRequests(withIdentifiers: PauseNudgePolicy.allIdentifiers)
        center.removeDeliveredNotifications(withIdentifiers: PauseNudgePolicy.allIdentifiers)
    }
}

extension PauseNudgeScheduler: UNUserNotificationCenterDelegate {
    /// Without this, iOS shows nothing while the app is active — and a rider paused to read the
    /// map, with the HUD on screen, is exactly that case (ROH-101 P5).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
