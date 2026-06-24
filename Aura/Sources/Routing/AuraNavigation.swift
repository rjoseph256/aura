import MapboxCommon
import MapboxNavigationCore

// NOTE on singleton enforcement:
// MapboxNavigationProvider (Mapbox Navigation v3) enforces a process-level
// singleton — constructing a second instance raises a fatal error.  All code
// that needs the Mapbox navigation stack (route fetching, active turn-by-turn
// guidance HUD, etc.) must reference this shared instance.

/// App-wide single owner of the Mapbox Navigation v3 stack.
///
/// `MapboxNavigationProvider` is a singleton — construct it once here and
/// reuse it for both route fetching (`MapboxRoutingProvider`) and active
/// turn-by-turn guidance (`NavigateHUDView`).  Main-actor isolated because
/// the Mapbox navigation stack is `@MainActor`-isolated.
///
/// Usage from the navigate-HUD task:
/// ```swift
/// // Obtain the shared MapboxNavigation instance (already @MainActor):
/// let nav = await AuraNavigation.provider.mapboxNavigation
/// // Start active guidance from a NavigationRoutes value:
/// nav.startActiveNavigation(with: .init(navigationRoutes: routes))
/// ```
@MainActor
public enum AuraNavigation {
    /// The single shared `MapboxNavigationProvider`.  Lazily initialised on
    /// first access; retained for the app's lifetime.
    public static let provider: MapboxNavigationProvider = {
        // MapboxOptions.accessToken is set at launch by AuraApp.configureMapbox().
        // We must pass the token explicitly because our token lives in a bundled
        // file (not Info.plist); reading from Info.plist would crash.
        let token = MapboxOptions.accessToken
        let coreConfig = CoreConfig(credentials: .init(accessToken: token))
        return MapboxNavigationProvider(coreConfig: coreConfig)
    }()
}
