import UIKit
import UserNotifications

/// Exists only to install the notification-centre delegate, which is what stops iOS suppressing
/// every banner while the app is active — the case a rider paused with the HUD on screen is in.
///
/// Installed at launch rather than lazily because the delegate has to be in place before the
/// first notification can arrive, and a ride can begin on the first frame via a deep link. It
/// does **not** currently handle taps: `PauseNudgeScheduler` implements `willPresent` and no
/// `didReceive`, so tapping a nudge just foregrounds the app.
final class AuraAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil)
    -> Bool {
        UNUserNotificationCenter.current().delegate = PauseNudgeScheduler.shared
        return true
    }
}
