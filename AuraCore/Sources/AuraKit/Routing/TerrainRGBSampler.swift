import Foundation
import AuraCore

/// The Terrain-RGB sampling orchestration, extracted from the app provider
/// (ROH-94) so package tests execute the exact pipeline production runs:
/// proportional sample count → evenly-spaced indices → tile/pixel placements →
/// dedupe unique tiles → fetch each once (concurrently, via the injected
/// lookup) → read samples in route order, dropping any unavailable sample.
///
/// BEST-EFFORT like the provider it came from: a missing tile or pixel drops
/// that sample; no elevation is ever fabricated.
public enum TerrainRGBSampler {

    public static func elevations(along coordinates: [Coordinate], zoom: Int,
                                  spacingMeters: Double = 150, minSamples: Int = 16, maxSamples: Int = 96,
                                  tile: @escaping @Sendable (TerrainTileID) async -> TerrainRGBTile?) async -> [Double] {
        let count = ElevationSampling.proportionalCount(coordinates: coordinates, spacingMeters: spacingMeters,
                                                        minCount: minSamples, maxCount: maxSamples)
        let indices = ElevationSampling.sampleIndices(total: coordinates.count, count: count)
        guard !indices.isEmpty else { return [] }
        let sampled = indices.map { coordinates[$0] }

        let placements = sampled.map {
            TerrainRGBPlacement.placement(lat: $0.latitude, lon: $0.longitude, z: zoom)
        }
        let uniqueTiles = Set(placements.map { TerrainTileID(z: zoom, x: $0.tileX, y: $0.tileY) })

        // Fetch each unique tile once, concurrently (a short route usually
        // touches only 1–4 tiles).
        var tiles: [TerrainTileID: TerrainRGBTile] = [:]
        await withTaskGroup(of: (TerrainTileID, TerrainRGBTile?).self) { group in
            for id in uniqueTiles {
                group.addTask { (id, await tile(id)) }
            }
            for await (id, decoded) in group {
                if let decoded { tiles[id] = decoded }
            }
        }

        // Read each sampled point's elevation in route order.
        var out: [Double] = []
        out.reserveCapacity(placements.count)
        for p in placements {
            let id = TerrainTileID(z: zoom, x: p.tileX, y: p.tileY)
            if let e = tiles[id]?.elevation(px: p.px, py: p.py) {
                out.append(e)
            }
        }
        return out
    }
}
