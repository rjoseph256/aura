import SwiftUI
import WidgetKit

/// The widget extension's entry point: the in-progress-ride Live Activity plus the
/// home / Lock Screen timeline widgets.
@main
struct AuraWidgetBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivity()
        WeeklyGoalWidget()
    }
}
