import UIKit

/// Opens the system Settings app at this app's page, for the permission sheet's
/// "Open Settings" action. Shared by both ride HUDs.
@MainActor
enum RideSettingsLink {
    static func open() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
