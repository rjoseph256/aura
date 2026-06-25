import UIKit

/// Keeps the display awake while a ride records, so a handlebar-mounted phone stays
/// glanceable. Display concern, kept out of the location layer. Reset on every end path.
@MainActor
enum RideScreen {
    static func keepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }
}
