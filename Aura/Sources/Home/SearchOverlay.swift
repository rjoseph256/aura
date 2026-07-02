import SwiftUI
import AuraCore

/// The expanded search state only: a dimming scrim, the focused field (DestinationSearchView),
/// and results above everything. The container hides the sheet + launch band while this is up,
/// so nothing stacks. On pick/cancel it clears + collapses.
struct SearchOverlay: View {
    @Binding var query: String
    let onPick: (Place) -> Void
    let onCollapse: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            AuraTheme.background.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { collapse() }

            VStack(spacing: AuraTheme.Spacing.md) {
                HStack(spacing: AuraTheme.Spacing.sm) {
                    DestinationSearchView(query: $query, isFocused: $fieldFocused) { place in
                        onPick(place)
                        collapse()
                    }
                    Button("Cancel") { collapse() }
                        .foregroundStyle(AuraTheme.accent)
                        .accessibilityIdentifier("home.searchCancel")
                        .padding(.trailing, AuraTheme.Spacing.xxl)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, AuraTheme.Spacing.md)
        }
        .task { fieldFocused = true }
    }

    private func collapse() {
        query = ""
        fieldFocused = false
        onCollapse()
    }
}
