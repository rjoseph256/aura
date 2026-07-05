import AuraKit
import CoreLocation

/// Device compass heading (true north) as an AsyncStream. iOS-only; the offline detour
/// pointer consumes it. Not used on macOS (package CI never links this app file).
public final class CompassHeadingProvider: NSObject, HeadingProviding {
    public override init() { super.init() }

    public func headings() -> AsyncStream<Double> {
        #if os(iOS)
        return AsyncStream { continuation in
            let delegate = HeadingDelegate { continuation.yield($0) }
            let manager = CLLocationManager()
            manager.delegate = delegate
            manager.headingFilter = 3
            manager.startUpdatingHeading()
            continuation.onTermination = { _ in
                manager.stopUpdatingHeading()
                _ = delegate   // retain until termination
            }
        }
        #else
        return AsyncStream { $0.finish() }
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
