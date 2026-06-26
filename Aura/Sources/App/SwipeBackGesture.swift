import SwiftUI
import UIKit

extension View {
    /// Enables or disables the enclosing NavigationStack's interactive pop (edge swipe) for
    /// the screen it is attached to. Used to re-assert the swipe under a hidden navigation
    /// bar, and to stop an actively recording ride from being swiped away by accident.
    func swipeBackEnabled(_ enabled: Bool) -> some View {
        background(SwipeBackGestureToggle(enabled: enabled))
    }
}

/// Reaches the hosting UINavigationController and toggles its interactive-pop gesture. It is
/// the one piece of UIKit introspection in navigation; if the controller can't be found the
/// gesture stays at the system default, which fails safe rather than crashing. Everything
/// runs in synchronous main-actor contexts (updateUIViewController and didMove are
/// @MainActor), so there is no Sendable capture to trip Swift 6 strict concurrency.
private struct SwipeBackGestureToggle: UIViewControllerRepresentable {
    let enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.desiredEnabled = enabled
        controller.applyToNavigationController()
    }

    final class Controller: UIViewController {
        var desiredEnabled = true

        // didMove fires once the controller is in the hierarchy, when the parent
        // navigation controller is resolvable; updateUIViewController re-applies on changes.
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyToNavigationController()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyToNavigationController()
        }

        func applyToNavigationController() {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = desiredEnabled
        }
    }
}
