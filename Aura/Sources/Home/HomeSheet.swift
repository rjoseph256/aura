import SwiftUI
import AuraCore

/// The Home dashboard as a system sheet with three detents, always presented and
/// non-dismissable, with background interaction so the terrain + launch band stay live
/// beneath it. Using `.presentationDetents` means SwiftUI arbitrates the drag vs the inner
/// ScrollView — no custom gesture. Peek shows the peek header (glance + last ride);
/// dragging up scrolls the body (recents, saved).
///
/// An optional `selection` binding lets Home drive the detent programmatically (the Saved
/// chip raises it to `.large`); when it reaches `.large` the body scrolls to the `"saved"`
/// anchor so the Saved section is revealed even if the body had been scrolled to Recents.
private struct HomeDashboardSheet<PeekHeader: View, Body: View>: ViewModifier {
    @Binding var isPresented: Bool
    var selection: Binding<PresentationDetent>?
    let peekHeight: CGFloat
    @ViewBuilder let peek: () -> PeekHeader
    @ViewBuilder let body: () -> Body

    private var detents: Set<PresentationDetent> { [.height(peekHeight), .fraction(0.55), .large] }

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ScrollViewReader { proxy in
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
                .modifier(DetentsModifier(detents: detents, selection: selection))
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
                .presentationBackground(AuraTheme.surface)
                .onChange(of: selection?.wrappedValue) { _, new in
                    if new == .large { withAnimation { proxy.scrollTo("saved", anchor: .top) } }
                }
            }
        }
    }
}

/// Applies `.presentationDetents` with a selection binding when provided, plain otherwise —
/// so callers that don't drive the detent keep the original drag-only behavior.
private struct DetentsModifier: ViewModifier {
    let detents: Set<PresentationDetent>
    let selection: Binding<PresentationDetent>?

    @ViewBuilder func body(content: Content) -> some View {
        if let selection {
            content.presentationDetents(detents, selection: selection)
        } else {
            content.presentationDetents(detents)
        }
    }
}

extension View {
    /// Presents the always-on Home dashboard sheet. `peek` is the non-scrolling peek header
    /// (motivation hook + last-ride card); `body` scrolls (recents, saved) at larger detents.
    /// Pass `selection` to drive the detent programmatically and enable scroll-to-"saved".
    func homeDashboardSheet<PeekHeader: View, Body: View>(
        isPresented: Binding<Bool>,
        selection: Binding<PresentationDetent>? = nil,
        peekHeight: CGFloat,
        @ViewBuilder peek: @escaping () -> PeekHeader,
        @ViewBuilder body: @escaping () -> Body
    ) -> some View {
        modifier(HomeDashboardSheet(isPresented: isPresented, selection: selection,
                                    peekHeight: peekHeight, peek: peek, body: body))
    }
}
