import SwiftUI
import AuraCore

/// The Home dashboard as a system sheet with three detents, always presented and
/// non-dismissable, with background interaction so the terrain + launch band stay live
/// beneath it. Using `.presentationDetents` means SwiftUI arbitrates the drag vs the inner
/// ScrollView — no custom gesture. Peek shows the peek header (glance + last ride);
/// dragging up scrolls the body (recents, saved).
private struct HomeDashboardSheet<PeekHeader: View, Body: View>: ViewModifier {
    @Binding var isPresented: Bool
    let peekHeight: CGFloat
    @ViewBuilder let peek: () -> PeekHeader
    @ViewBuilder let body: () -> Body

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            VStack(spacing: AuraTheme.Spacing.md) {
                peek()
                    .padding(.horizontal, AuraTheme.Spacing.xxl)
                    .padding(.top, AuraTheme.Spacing.lg)
                ScrollView {
                    body().padding(.horizontal, AuraTheme.Spacing.xxl)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .presentationDetents([.height(peekHeight), .fraction(0.55), .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
            .presentationBackground(AuraTheme.surface)
        }
    }
}

extension View {
    /// Presents the always-on Home dashboard sheet. `peek` is the non-scrolling peek header
    /// (motivation hook + last-ride card); `body` scrolls (recents, saved) at larger detents.
    func homeDashboardSheet<PeekHeader: View, Body: View>(
        isPresented: Binding<Bool>,
        peekHeight: CGFloat,
        @ViewBuilder peek: @escaping () -> PeekHeader,
        @ViewBuilder body: @escaping () -> Body
    ) -> some View {
        modifier(HomeDashboardSheet(isPresented: isPresented, peekHeight: peekHeight, peek: peek, body: body))
    }
}
