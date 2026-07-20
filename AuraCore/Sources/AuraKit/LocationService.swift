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

    /// The current location tier. Drives which manager configuration is active and
    /// whether the background session/indicator is armed. Read by the RootView controller
    /// and tests; not observed by any view, so it is observation-ignored.
    @ObservationIgnored public private(set) var mode: LocationAccuracyMode = .idle

    /// True while the ride pipeline holds the background location session. On macOS (no
    /// `CLBackgroundActivitySession`) it still tracks the ride's intent, so the teardown
    /// guarantee is unit-testable on the CI host. Only `points()` sets it; only `stop()` clears it.
    @ObservationIgnored public private(set) var sessionActive = false

    /// Identifies the current ride session. Bumped by each `points()`; the stream's
    /// `onTermination` backstop captures it and only tears down if it is still current, so a
    /// stale termination from a prior ride can never invalidate a newly-started ride's session.
    @ObservationIgnored private var rideSessionID = 0

    /// A dedicated manager for one-shot `current()` fixes, kept separate from the ambient
    /// `manager` so a one-shot and the continuous ambient monitor never share delegate state.
    @ObservationIgnored let oneShotManager = CLLocationManager()

    /// Most recent ambient (coarse, Home-foreground) fix. Drives weather refresh and the
    /// `.coarse` branch of `current()`. Nil until the ambient monitor delivers.
    public private(set) var lastKnown: LocationFix?

    /// Single-slot continuation for the in-flight one-shot fix; resumed exactly once (the
    /// resumer nils it first, so any later callback is a no-op). Internal for test observation.
    @ObservationIgnored var oneShotContinuation: CheckedContinuation<Coordinate?, Never>?

    /// The in-flight one-shot request. Concurrent `current()` callers await this same task
    /// instead of starting a second `requestLocation()`. Internal for test observation.
    @ObservationIgnored var oneShotTask: Task<Coordinate?, Never>?

    /// Bumped every time a one-shot cycle resolves. A cycle's timeout captures the value at
    /// launch and no-ops if it has since advanced — so a completed cycle's still-sleeping timer
    /// can never drain a *later* cycle's continuation (the cross-cycle contamination trap).
    @ObservationIgnored private var oneShotGeneration = 0

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var continuation: AsyncStream<TrackPoint>.Continuation?
    #if os(iOS)
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    #endif
    public override init() {
        super.init()
        manager.delegate = self
        oneShotManager.delegate = self
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
            timestamp: location.timestamp,
            // CLLocation.speed is -1 when the platform can't compute it; keep only
            // valid readings (0 is a legitimate stopped reading and must be kept).
            speedMetersPerSecond: location.speed >= 0 ? location.speed : nil)
    }

    /// Configure the shared manager for a tier. Sets EVERY relevant knob for EVERY tier
    /// so no setting (e.g. an ambient 500 m `distanceFilter`) can leak across a transition.
    /// Only `.navigating` arms the visible background indicator; the iOS-only knobs are
    /// guarded so the package still builds for macOS.
    public func setMode(_ mode: LocationAccuracyMode) {
        self.mode = mode
        switch mode {
        case .idle:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = kCLDistanceFilterNone
        case .ambient:
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            manager.distanceFilter = 500
        case .navigating:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = kCLDistanceFilterNone
        }
        #if os(iOS)
        manager.activityType = (mode == .idle) ? .other : .fitness
        manager.pausesLocationUpdatesAutomatically = (mode != .navigating)
        manager.showsBackgroundLocationIndicator = (mode == .navigating)
        #endif
    }

    public func points() -> AsyncStream<TrackPoint> {
        stop()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        setMode(.navigating)
        sessionActive = true
        rideSessionID &+= 1
        let sessionID = rideSessionID
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
            // Backstop: if the consumer drops the stream without an explicit stop(), tear down.
            // Guarded by the session token so a stale termination from THIS ride can never
            // invalidate a newer ride's session — only tear down if this session is still current.
            Task { @MainActor in
                guard let self, self.rideSessionID == sessionID else { return }
                self.stop()
            }
        }
        return stream
    }

    public func stop() {
        updatesTask?.cancel(); updatesTask = nil
        #if os(iOS)
        backgroundSession?.invalidate(); backgroundSession = nil
        #endif
        continuation?.finish(); continuation = nil
        sessionActive = false
        // Only return the manager to idle if WE still own it as the ride. If the lifecycle
        // controller already re-armed `.ambient` (ride-end race: path pop fires startAmbient
        // before the HUD's onDisappear->cancel->stop lands), don't clobber it. The session
        // teardown above is unconditional; only the tier reset is guarded.
        if mode == .navigating { setMode(.idle) }
        signal = .good
    }

    /// Start the coarse, foreground-only ambient monitor used for Home weather. Gated on real
    /// authorization so it never triggers the permission prompt (that stays on the ride path)
    /// and never runs unauthorized. No background session, indicator off (see `setMode`). No-op
    /// if a ride owns the manager.
    public func startAmbient() {
        guard authorization == .authorized, mode != .navigating else { return }
        setMode(.ambient)
        manager.startUpdatingLocation()
    }

    /// Release the continuous NON-ride location: stop the ambient monitor and return to idle.
    /// A no-op while navigating so it can be called freely from the app lifecycle controller
    /// without ever interrupting a recording ride. An in-flight one-shot `current()` is left to
    /// self-resolve (it is bounded by its own timeout and holds no session/indicator).
    public func releaseNonRide() {
        guard mode != .navigating else { return }
        manager.stopUpdatingLocation()
        setMode(.idle)
    }

    /// Route a delegate fix to the right consumer by manager identity: the one-shot manager
    /// resolves the in-flight `current()` request; any other manager (the ambient `manager`)
    /// records `lastKnown`. Internal so unit tests can drive it without a device.
    @MainActor func handleLocationUpdate(managerID: ObjectIdentifier, coordinate: Coordinate, accuracy: Double, timestamp: Date) {
        if managerID == ObjectIdentifier(oneShotManager) {
            resolveOneShot(with: coordinate)
        } else {
            lastKnown = LocationFix(coordinate: coordinate, horizontalAccuracy: accuracy, at: timestamp)
        }
    }

    /// A one-shot failure resolves the request with nil (caller falls back). Ambient failures ignored.
    @MainActor func handleLocationFailure(managerID: ObjectIdentifier) {
        guard managerID == ObjectIdentifier(oneShotManager) else { return }
        resolveOneShot(with: nil)
    }

    /// Resolve the in-flight one-shot exactly once: nil the slot, advance the generation (so this
    /// cycle's still-sleeping timeout can never fire into a later cycle), and cancel any pending
    /// `requestLocation` (so a late delegate callback from a timed-out cycle can't leak into the
    /// next). No-op if nothing is in flight.
    @MainActor private func resolveOneShot(with coordinate: Coordinate?) {
        guard let cont = oneShotContinuation else { return }
        oneShotContinuation = nil
        oneShotGeneration &+= 1
        oneShotManager.stopUpdatingLocation()
        cont.resume(returning: coordinate)
    }

    /// One-shot origin for plan/preview and Home weather, with a Pittsburgh fallback. Never
    /// throws and never opens a continuous stream. Resolution: a fresh *precise* cached fix wins
    /// (routing rejects a coarse cached fix — see `resolveOrigin`); a `.coarse` caller may take a
    /// fresh ambient fix; otherwise a single `requestLocation()` on the dedicated one-shot manager,
    /// bounded by a timeout, then the fallback.
    public func current(for purpose: LocationPurpose = .routing) async -> Coordinate {
        let fallback = Coordinate(latitude: 40.4406, longitude: -79.9959)
        let now = Date()
        let cached = manager.location.map {
            LocationFix(coordinate: Coordinate(latitude: $0.coordinate.latitude,
                                               longitude: $0.coordinate.longitude),
                        horizontalAccuracy: $0.horizontalAccuracy, at: $0.timestamp)
        }
        if let resolved = resolveOrigin(cached: cached, ambient: lastKnown, purpose: purpose, now: now) {
            return resolved
        }
        switch manager.authorizationStatus {
        case .denied, .restricted: return fallback
        default: break
        }
        return await firstOneShotCoordinate() ?? fallback
    }

    /// Await a single fix from the dedicated one-shot manager, bounded by `timeout`. Concurrent
    /// callers coalesce onto one `oneShotTask` (and thus one `requestLocation()`); the single-slot
    /// `oneShotContinuation` is resumed exactly once — by the delegate on success/failure or by the
    /// timeout below, whichever nils it first; the loser sees nil and no-ops. The timeout task is
    /// never cancelled (avoids the Swift 6.2 cancel-while-sleeping abort). Do NOT reintroduce a
    /// `withTaskGroup` race: `withCheckedContinuation` ignores cancellation, so a parked waiter
    /// would keep the group's implicit await-all alive past the timeout and hang `current()`.
    private func firstOneShotCoordinate(timeout: TimeInterval = 3) async -> Coordinate? {
        if let task = oneShotTask { return await task.value }   // coalesce concurrent callers
        let task = Task { @MainActor [weak self] () -> Coordinate? in
            guard let self else { return nil }
            let generation = self.oneShotGeneration
            return await withCheckedContinuation { (cont: CheckedContinuation<Coordinate?, Never>) in
                self.oneShotContinuation = cont
                self.oneShotManager.requestLocation()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    // Only this cycle's timeout may resolve it; a newer cycle owns the slot now.
                    guard self.oneShotGeneration == generation else { return }
                    self.resolveOneShot(with: nil)
                }
            }
        }
        oneShotTask = task
        let result = await task.value
        oneShotTask = nil
        return result
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        // Snapshot the Sendable status synchronously so the non-Sendable manager `m`
        // never crosses into the main-actor Task (Swift 6 region isolation).
        let status = m.authorizationStatus
        Task { @MainActor in self.authorization = LocationAuthorization(status) }
    }

    nonisolated public func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Extract Sendable values synchronously; CLLocation is not Sendable.
        guard let loc = locations.last else { return }
        let coord = Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        let acc = loc.horizontalAccuracy
        let ts = loc.timestamp
        let id = ObjectIdentifier(m)
        Task { @MainActor in self.handleLocationUpdate(managerID: id, coordinate: coord, accuracy: acc, timestamp: ts) }
    }

    nonisolated public func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let id = ObjectIdentifier(m)
        Task { @MainActor in self.handleLocationFailure(managerID: id) }
    }
}
