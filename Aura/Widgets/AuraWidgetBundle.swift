import SwiftUI
import WidgetKit

/// The widget extension's entry point. Today it hosts only the in-progress-ride Live
/// Activity; home-screen / Lock Screen timeline widgets would be added here too.
@main
struct AuraWidgetBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivity()
    }
}
