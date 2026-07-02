import SwiftUI
import AuraCore

/// One saved destination on the dashboard. Same anatomy as RecentRow, with a
/// kind icon, a subtitle line, and a visible ellipsis menu (the HIG-required
/// second path beside the long-press context menu).
struct SavedPlaceRow: View {
    let saved: SavedPlace
    let onTap: () -> Void
    let onRename: () -> Void
    let onSetHome: () -> Void
    let onRemoveHome: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: AuraTheme.Spacing.lg) {
                    Image(systemName: saved.kind == .home ? "house.fill" : "star.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AuraTheme.accent)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(AuraTheme.textPrimary)
                            .lineLimit(1)
                        if let line = subtitleLine {
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(AuraTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .frame(minHeight: 56)
                .padding(.leading, AuraTheme.Spacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The Button is one accessibility element; the composed label and
            // the custom actions live here so the ellipsis Menu stays its own
            // queryable element (do NOT .combine the whole row — it swallows
            // the menu from both VoiceOver and XCUITest).
            .accessibilityLabel(accessibilityText)
            .accessibilityAction(named: "Rename", onRename)
            .accessibilityAction(named: saved.kind == .home ? "Remove Home" : "Set as Home") {
                if saved.kind == .home { onRemoveHome() } else { onSetHome() }
            }
            .accessibilityAction(named: "Delete", onDelete)

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .frame(width: 44, height: 56)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(title)")
        }
        .contextMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Rename", systemImage: "pencil", action: onRename)
        if saved.kind == .home {
            Button("Remove Home", systemImage: "house.slash", action: onRemoveHome)
        } else {
            Button("Set as Home", systemImage: "house", action: onSetHome)
        }
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }

    /// Home renders as the concept, with the actual place demoted to context.
    private var title: String { saved.kind == .home ? "Home" : saved.name }

    /// Home shows the actual place's name (spec D6); favorites show the
    /// address line with the category label as fallback.
    private var subtitleLine: String? {
        if saved.kind == .home { return saved.name }
        return saved.subtitle ?? categoryLabel
    }

    private var categoryLabel: String {
        switch saved.category {
        case .brewery:   return "Brewery"
        case .trailhead: return "Trail"
        case .address:   return "Address"
        case .custom:    return "Place"
        }
    }

    private var accessibilityText: String {
        let line = subtitleLine.map { ", \($0)" } ?? ""
        return "\(title)\(line)"
    }
}
