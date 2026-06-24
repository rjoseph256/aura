import Foundation
import CoreLocation
import Observation
import AuraCore

@Observable
@MainActor
public final class LocationService: NSObject, LocationStreaming {
    public private(set) var authorization: LocationAuthorization = .notDetermined
    public private(set) var signal: SignalQuality = .good

    @ObservationIgnored let manager = CLLocationManager()

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var continuation: AsyncStream<TrackPoint>.Continuation?
    #if os(iOS)
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    #endif
    public override init() {
        super.init()
        manager.delegate = self
        authorization = LocationAuthorization(manager.authorizationStatus)
    }

    /// Classify + filter one fix. Updates `signal`; returns a TrackPoint only if the
    /// fix is acceptable for the recorded track. Pure logic, unit-tested.
    func ingest(_ location: CLLocation, now: Date) -> TrackPoint? {
        let age = now.timeIntervalSince(location.timestamp)
        signal = GPSFix.quality(horizontalAccuracy: location.horizontalAccuracy, age: age)
        guard GPSFix.isAcceptable(horizontalAccuracy: location.horizontalAccuracy) else { return nil }
        return TrackPoint(
            coordinate: Coordinate(latitude: location.coordinate.latitude,
                                   longitude: location.coordinate.longitude),
            elevation: location.altitude,
            timestamp: location.timestamp)
    }

    /// Map the desired-accuracy tier onto CoreLocation. Coarse when idle (battery),
    /// the cycling tier while recording. The iOS-only knobs (fitness activity type,
    /// no auto-pause, visible background indicator) are guarded so the package still
    /// builds for macOS.
    public func setMode(_ mode: LocationAccuracyMode) {
        manager.desiredAccuracy = (mode == .navigating)
            ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
        #if os(iOS)
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        #endif
    }

    public func points() -> AsyncStream<TrackPoint> {
        stop()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        setMode(.navigating)
        #if os(iOS)
        // A background activity session keeps location flowing when the app is
        // backgrounded; it replaces the legacy `allowsBackgroundLocationUpdates` flag.
        backgroundSession = CLBackgroundActivitySession()
        #endif
        let (stream, continuation) = AsyncStream<TrackPoint>.makeStream()
        self.continuation = continuation
        updatesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let loc = update.location, let point = self.ingest(loc, now: Date()) {
                        continuation.yield(point)
                    } else if #available(iOS 18, macOS 15, *), update.locationUnavailable {
                        self.signal = .lost
                    }
                }
            } catch {
                // A thrown error ends the stream (e.g. authorization revoked mid-ride); reflect it.
                signal = .lost
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            // onTermination fires off the main actor when the consumer drops the
            // stream; hop back in to tear down the manager state.
            Task { @MainActor in self?.stop() }
        }
        return stream
    }

    public func stop() {
        updatesTask?.cancel(); updatesTask = nil
        #if os(iOS)
        backgroundSession?.invalidate(); backgroundSession = nil
        #endif
        continuation?.finish(); continuation = nil
        setMode(.idle)
    }

    /// One-shot origin for the plan/preview, with a Pittsburgh fallback. Folds in
    /// the old `CurrentLocationProvider` role. Never throws; resolves quickly: a fresh
    /// cached fix wins immediately, otherwise it races a single live update against a
    /// 3s timeout and falls back rather than hanging the UI.
    public func current() async -> Coordinate {
        let fallback = Coordinate(latitude: 40.4406, longitude: -79.9959)
        if let loc = manager.location, -loc.timestamp.timeIntervalSinceNow < 30 {
            return Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        }
        switch manager.authorizationStatus {
        case .denied, .restricted: return fallback
        default: break
        }
        return await withTaskGroup(of: Coordinate?.self) { group in
            group.addTask { @MainActor in
                if let u = try? await CLLocationUpdate.liveUpdates().first(where: { $0.location != nil }),
                   let l = u.location {
                    return Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
                }
                return nil
            }
            group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? fallback
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in self.authorization = LocationAuthorization(m.authorizationStatus) }
    }
}
