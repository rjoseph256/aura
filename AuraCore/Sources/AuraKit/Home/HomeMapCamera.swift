import Foundation
import AuraCore

/// The Home map's camera (center + zoom), shared by the idle snapshot and the live map so they
/// cannot drift. Pure — the app target maps this onto a MapboxMaps `Viewport`.
public struct HomeMapCamera: Equatable, Sendable {
    public var center: Coordinate
    public var zoom: Double
    public init(center: Coordinate, zoom: Double) { self.center = center; self.zoom = zoom }

    public static let defaultZoom: Double = 12.5   // matches the legacy snapshot zoom
    public static let minZoom: Double = 10.5
    public static let maxZoom: Double = 17.0

    public static func initial(forRider rider: Coordinate?) -> HomeMapCamera {
        HomeMapCamera(center: TerrainSnapshotRequest.center(forRider: rider), zoom: defaultZoom)
    }
    public func clampedZoom() -> HomeMapCamera {
        HomeMapCamera(center: center, zoom: min(max(zoom, Self.minZoom), Self.maxZoom))
    }
}

public enum HomeCameraResetEvent: Sendable, Equatable { case coldLaunch, rideCompleted, returnedToHome }

public extension HomeMapCamera {
    /// Resets to the rider only on cold launch or after a completed ride; a plain return to Home
    /// preserves the rider's panned camera (ROH-84 session persistence).
    static func shouldReset(on event: HomeCameraResetEvent) -> Bool {
        switch event { case .coldLaunch, .rideCompleted: return true; case .returnedToHome: return false }
    }
}
