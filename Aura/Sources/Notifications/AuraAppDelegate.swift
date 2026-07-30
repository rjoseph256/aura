import UIKit
import UserNotifications

/// Exists only to install the notification-centre delegate before launch finishes. A delegate
/// set later than that misses a launch-time tap response, and without one iOS suppresses every
/// foreground banner.
final class AuraAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil)
    -> Bool {
        UNUserNotificationCenter.current().delegate = PauseNudgeScheduler.shared
        return true
    }
}
