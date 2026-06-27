import UIKit

/// Opens the Health app so the rider can grant or revoke Aura's data access. The
/// Health sharing screen is not reliably deep-linkable, so this lands on Health's
/// home; `x-apple-health://` is the documented scheme.
enum HealthAppLink {
    @MainActor static func open() {
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url)
    }
}
