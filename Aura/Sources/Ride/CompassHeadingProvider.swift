import AuraKit
import CoreLocation

/// Device compass heading (true north) as an AsyncStream. iOS-only; the offline detour
/// pointer consumes it. Not used on macOS (package CI never links this app file).
///
/// `@MainActor`-isolated: the app target uses Swift 6 strict concurrency with default
/// main-actor isolation, and `CLLocationManager`/its delegate must be driven from one
/// consistent isolation domain. A `@MainActor` class is implicitly `Sendable`, so this
/// still satisfies `HeadingProviding: Sendable` even though `headings()` itself is
/// `nonisolated` (called from non-isolated contexts; it hops to the main actor internally
/// via `Task { @MainActor in ... }` for both setup and teardown).
@MainActor
public final class CompassHeadingProvider: NSObject, HeadingProviding {
    #if os(iOS)
    private var manager: CLLocationManager?
    private var delegate: HeadingDelegate?
    #endif

    public override init() { super.init() }

    public nonisolated func headings() -> AsyncStream<Double> {
        #if os(iOS)
        AsyncStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let delegate = HeadingDelegate { continuation.yield($0) }
                let manager = CLLocationManager()
                manager.delegate = delegate
                manager.headingFilter = 3
                self.manager = manager
                self.delegate = delegate
                manager.startUpdatingHeading()
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.manager?.stopUpdatingHeading()
                    self?.manager = nil
                    self?.delegate = nil
                }
            }
        }
        #else
        AsyncStream { $0.finish() }
        #endif
    }
}

#if os(iOS)
private final class HeadingDelegate: NSObject, CLLocationManagerDelegate {
    let onHeading: (Double) -> Void
    init(onHeading: @escaping (Double) -> Void) { self.onHeading = onHeading }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let deg = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        onHeading(deg)
    }
}
#endif
