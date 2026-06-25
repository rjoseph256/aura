import UIKit
import AuraKit

/// Keeps the display awake while a ride records, so a handlebar-mounted phone stays
/// glanceable. The UIKit-backed conformer of `ScreenWakeControlling`; the coordinator
/// in AuraKit drives it through the seam.
@MainActor
final class ScreenWakeController: ScreenWakeControlling {
    func setKeepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }
}
