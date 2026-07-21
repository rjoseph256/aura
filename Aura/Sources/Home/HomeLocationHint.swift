import SwiftUI
import UIKit

/// Quiet, actionable affordance shown when location is unavailable, so a rider in another city
/// understands why the map isn't on them. Not an error banner.
struct HomeLocationHint: View {
    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            Label("Location off — showing a default area", systemImage: "location.slash")
                .font(.footnote.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AuraTheme.textSecondary)
        .accessibilityHint("Opens Settings to enable location")
        .accessibilityIdentifier("home.locationHint")
    }
}
