import Foundation
import AuraCore

/// Region cache for the live feed: refetch only when the rider leaves the current cell or
/// the entry goes stale. Actor-isolated; the clock is injected (`now`), never wall-clock.
public actor GemRegionCache {
    private struct Entry { let cell: Cell; let at: Date; let gems: [Gem] }
    private struct Cell: Equatable { let x: Int; let y: Int }

    private let cellMeters: Double
    private let stalenessSeconds: TimeInterval
    private var entry: Entry?

    public init(cellMeters: Double = 2000, stalenessSeconds: TimeInterval = 600) {
        self.cellMeters = cellMeters
        self.stalenessSeconds = stalenessSeconds
    }

    public func gems(near coordinate: Coordinate, now: Date,
                     fetch: @Sendable () async -> [Gem]) async -> [Gem] {
        let cell = self.cell(for: coordinate)
        if let e = entry, e.cell == cell, now.timeIntervalSince(e.at) < stalenessSeconds {
            return e.gems
        }
        let gems = await fetch()
        entry = Entry(cell: cell, at: now, gems: gems)
        return gems
    }

    private func cell(for c: Coordinate) -> Cell {
        // ~metersPerDegree lat; lon scaled by cos(lat) so cells are roughly square.
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(c.latitude * .pi / 180)
        return Cell(x: Int((c.longitude * mPerDegLon / cellMeters).rounded()),
                    y: Int((c.latitude * mPerDegLat / cellMeters).rounded()))
    }
}
