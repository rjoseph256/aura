import SwiftUI
import UIKit
import AuraKit

// Extracted from `RideSummaryView` in ROH-178: the view was over this repo's 500-line limit, and
// "is the share sheet on screen" is a self-contained question about the live UIKit window rather
// than part of rendering a summary. The stale doc comment that used to sit here — "whether the app
// is currently presenting a modal" — described the bug, not the intent, and is gone with it.

@MainActor
enum SharePresentation {
    /// Whether the **share sheet** is on screen — not whether anything is.
    ///
    /// ROH-178: this used to read `rootViewController?.presentedViewController != nil`, one level
    /// down from the key window's root. That is true of *any* modal, and on the History path
    /// `RideSummaryView` is itself the presented sheet (`HistoryView.swift:53`), so the old
    /// predicate was true from the moment the summary appeared, before any Share tap. Measured on
    /// a simulator: chain depth 1 on the History path against 0 on the pushed ride-end path, with
    /// no sheet tapped on either. `beginShareSheetWatch` then latched for the summary's whole
    /// lifetime and every upgrade was deferred into a dying view — the defect the latch exists to
    /// prevent, inverted.
    ///
    /// So it now walks the whole chain and looks for the thing it actually means.
    /// `UIActivityViewController` is what `ShareLink` presents; SwiftUI documents no such
    /// guarantee, so `SharePresentationUITests` pins it. If a future release wraps the sheet in
    /// something else this predicate silently returns false, upgrades stop being deferred, and the
    /// 2026-07-31 self-dismiss defect returns — which is why that test is not optional.
    ///
    /// Deliberately not a seam: it answers a question about the live UIKit window, which a stub
    /// could only lie about.
    static var isPresentingShareSheet: Bool { chain().hasActivitySheet }

    /// The presentation chain over the key window's root: how deep it runs, and whether the share
    /// sheet is in it. `depth` is kept because it is the diagnostic that distinguishes "my sheet is
    /// up" from "I am inside a sheet", which is the whole of ROH-178.
    static func chain() -> SharePresentationProbe.Values {
        var controller = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
        var depth = 0
        var activity = false
        while let presented = controller?.presentedViewController {
            depth += 1
            if presented is UIActivityViewController { activity = true }
            controller = presented
        }
        return SharePresentationProbe.Values(depth: depth, hasActivitySheet: activity)
    }
}

/// ROH-178 diagnostic overlay. Same shape and gating as `SimulatedRideProbe`: DEBUG only,
/// simulated rides only, near-invisible, never intercepts touches. Polls because
/// `presentedViewController` changes do not invalidate a SwiftUI body, so a value sampled once
/// in `onAppear` would be stale exactly when the share sheet goes up.
struct SharePresentationProbeOverlay: ViewModifier {
    @State private var line = SharePresentationProbe.line(depth: 0, hasActivitySheet: false,
                                                          predicate: false)

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .overlay(alignment: .topLeading) {
                if SimulatedRideConfig.current != nil {
                    Text(line)
                        .font(.system(size: 8))
                        .opacity(0.02)
                        .accessibilityIdentifier(RideTestID.summaryPresentationProbe)
                        .allowsHitTesting(false)
                }
            }
            .task {
                guard SimulatedRideConfig.current != nil else { return }
                while !Task.isCancelled {
                    // Reads the PRODUCTION predicate, not a parallel walk, so the test guards the
                    // shipping behaviour rather than a copy of it.
                    let values = SharePresentation.chain()
                    line = SharePresentationProbe.line(depth: values.depth,
                                                       hasActivitySheet: values.hasActivitySheet,
                                                       predicate: SharePresentation.isPresentingShareSheet)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        #else
        content
        #endif
    }
}
