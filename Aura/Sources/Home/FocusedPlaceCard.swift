import SwiftUI
import AuraCore

/// Shown in the launch band's slot once a searched place has been flown to on the Home map
/// (`HomeView.focusedPlace`), replacing `HomeLaunchBand` while a destination pin is dropped.
/// Maps-style: the place identity up top, a dismiss to clear the pin, and one dominant
/// "Ride here" action that hands off to route preview. Mirrors the launch band's card
/// language (surface + `.ctaPrimary`) so it reads as the same system, not a new one.
struct FocusedPlaceCard: View {
    let place: Place
    var onRideHere: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.md) {
            HStack(spacing: AuraTheme.Spacing.md) {
                Image(systemName: categoryIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AuraTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)
                    if let subtitle = place.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(AuraTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: AuraTheme.Spacing.sm)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AuraTheme.textSecondary)
                }
                .accessibilityLabel("Clear destination")
                .accessibilityIdentifier("home.focusedPlace.dismiss")
            }

            Button(action: onRideHere) {
                Label("Ride here", systemImage: "bicycle")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ctaPrimary)
            .accessibilityLabel("Ride here, to \(place.name)")
            .accessibilityIdentifier("home.rideHere")
        }
        .padding(AuraTheme.Spacing.lg)
        .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    private var categoryIcon: String {
        switch place.category {
        case .brewery:   return "mug.fill"
        case .trailhead: return "figure.hiking"
        case .address:   return "mappin.circle.fill"
        case .custom:    return "mappin"
        }
    }
}

#Preview {
    ZStack {
        AuraTheme.background.ignoresSafeArea()
        FocusedPlaceCard(
            place: Place(name: "Frick Park", subtitle: "Trailhead",
                         coordinate: Coordinate(latitude: 40.4331, longitude: -79.9068),
                         category: .trailhead),
            onRideHere: {}, onDismiss: {})
    }
}
