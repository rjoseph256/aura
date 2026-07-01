import Foundation
import AuraCore

/// The group-ride session owner: create/join lifecycle, phase, and (in a later task)
/// the live tick layer. This file covers lifecycle only — `tick`/`ingest`/`peers`/
/// `nameMap`/`toasts`/`startTicker` are added by Task 10a/10b on top of this seam.
@MainActor
@Observable
public final class GroupRideSession {
    public enum Phase: Equatable, Sendable {
        case idle, lobby, riding, ended, routeUnavailable, createFailed, needsDisplayName
    }

    public private(set) var phase: Phase = .idle
    public private(set) var isHost: Bool = false
    public private(set) var rideID: UUID?
    public private(set) var joinCode: JoinCode?
    public private(set) var route: Route?

    private let backend: any GroupRideBackend
    private let transport: any RideSessionTransport
    private let displayNameProvider: @Sendable () -> String
    private let cadence: LiveShareCadence
    private var rideSession: RideSession?

    public init(backend: any GroupRideBackend, transport: any RideSessionTransport,
                displayNameProvider: @escaping @Sendable () -> String, cadence: LiveShareCadence = .init()) {
        self.backend = backend
        self.transport = transport
        self.displayNameProvider = displayNameProvider
        self.cadence = cadence
    }

    public func create(route inputRoute: Route) async {
        guard DisplayName.normalized(displayNameProvider()) != nil else {
            phase = .needsDisplayName
            return
        }
        do {
            let selfUserID = try await backend.currentUserID()
            let routeData = try JSONEncoder().encode(inputRoute)
            let ride = try await backend.createRide(route: routeData)
            rideID = ride.id
            joinCode = ride.joinCode
            route = inputRoute
            isHost = (ride.hostID == selfUserID)
            rideSession = RideSession(rideID: ride.id, selfUserID: selfUserID,
                                      transport: transport, cadence: cadence)
            phase = .lobby
        } catch {
            phase = .createFailed
        }
    }

    public func join(code: JoinCode) async {
        guard DisplayName.normalized(displayNameProvider()) != nil else {
            phase = .needsDisplayName
            return
        }
        do {
            let selfUserID = try await backend.currentUserID()
            let joined = try await backend.joinRide(code: code)
            guard let decodedRoute = try? JSONDecoder().decode(Route.self, from: joined.route) else {
                phase = .routeUnavailable
                try? await backend.leaveRide(rideID: joined.ride.id)
                return
            }
            rideID = joined.ride.id
            joinCode = joined.ride.joinCode
            route = decodedRoute
            isHost = (joined.ride.hostID == selfUserID)
            rideSession = RideSession(rideID: joined.ride.id, selfUserID: selfUserID,
                                      transport: transport, cadence: cadence)
            phase = .riding
        } catch {
            phase = .createFailed
        }
    }

    public func startRiding() {
        phase = .riding
    }
}
