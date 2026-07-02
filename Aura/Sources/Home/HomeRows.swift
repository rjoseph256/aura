import SwiftUI
import AuraCore

/// A recent-destination row in the Home dashboard sheet (moved out of the retired PlanView).
struct RecentRow: View {
    let place: Place
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AuraTheme.Spacing.lg) {
                Image(systemName: categoryIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AuraTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)

                    Text(categoryLabel)
                        .font(.footnote)
                        .foregroundStyle(AuraTheme.textSecondary)
                }
                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
            .frame(minHeight: 56)
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var categoryIcon: String {
        switch place.category {
        case .brewery:   return "mug.fill"
        case .trailhead: return "figure.hiking"
        case .address:   return "mappin.circle.fill"
        case .custom:    return "mappin"
        }
    }

    private var categoryLabel: String {
        switch place.category {
        case .brewery:   return "Brewery"
        case .trailhead: return "Trail"
        case .address:   return "Address"
        case .custom:    return "Place"
        }
    }
}
