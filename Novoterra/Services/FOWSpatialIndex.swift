import Foundation
import CoreLocation
import os

/// Memory-bounded spatial index over Fog of World tiles.
/// Holds only the tile file list; decompressed tiles are loaded on demand into a byte-budgeted LRU cache.
actor FOWSpatialIndex {

    private static let log = Logger(subsystem: "com.novoterra.app", category: "FOWSpatialIndex")

    // MARK: - Storage

    private var tiles: [Int: FOWTileMetadata] = [:]

    private var cache: [Int: FOWTile] = [:]
    private var cacheOrder: [Int] = []
    private var cacheBytes = 0
    private let maxCacheBytes: Int
    /// Tiles that failed to decode; skipped until the index is replaced.
    private var failedTiles: Set<Int> = []

    init(maxCacheBytes: Int = 96 * 1024 * 1024) {
        self.maxCacheBytes = maxCacheBytes
    }

    // MARK: - Registration

    /// Replace the whole index. Drops cached tile data because files may have changed.
    func replaceTiles(_ newTiles: [FOWTileMetadata]) {
        tiles = Dictionary(newTiles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        clearCache()
        failedTiles.removeAll()
    }

    var tileCount: Int { tiles.count }

    func hasTile(id: Int) -> Bool { tiles[id] != nil }

    // MARK: - Tile Access

    /// Decoded tile for the given ID, or nil if the user has never visited it.
    func tile(id: Int) -> FOWTile? {
        if let cached = cache[id] {
            touch(id)
            return cached
        }
        guard let metadata = tiles[id], !failedTiles.contains(id) else { return nil }

        do {
            let tile = try FOWParser.decodeTile(Data(contentsOf: metadata.fileURL, options: .mappedIfSafe))
            insert(tile, for: id)
            return tile
        } catch {
            failedTiles.insert(id)
            Self.log.error("Failed to load tile \(id): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Visited Checks

    /// Whether any FOW pixel within `radiusPixels` of the global pixel is visited.
    private func isVisitedNear(gx: Int, gy: Int, radiusPixels r: Int) -> Bool {
        let r2 = r * r
        var lastTileID = -1
        var lastTile: FOWTile?
        for dy in -r...r {
            for dx in -r...r where dx * dx + dy * dy <= r2 {
                let x = gx + dx, y = gy + dy
                guard x >= 0, y >= 0, x < MercatorProjection.WORLD_PIXELS, y < MercatorProjection.WORLD_PIXELS else { continue }
                let c = MercatorProjection.globalPixelToComponents(x, y)
                let id = c.tileID
                if id != lastTileID {
                    lastTileID = id
                    lastTile = tiles[id] == nil ? nil : tile(id: id)
                }
                if let lastTile, lastTile.isVisited(blockX: c.blockX, blockY: c.blockY, pixelX: c.pixelX, pixelY: c.pixelY) {
                    return true
                }
            }
        }
        return false
    }

    /// For each coordinate, whether the user has been within `toleranceMeters` of it.
    /// The tolerance absorbs GPS noise and the offset between recorded tracks and map road geometry.
    func visitedMask(for coordinates: [CLLocationCoordinate2D], toleranceMeters: Double) -> [Bool] {
        guard !tiles.isEmpty else { return Array(repeating: false, count: coordinates.count) }
        return coordinates.map { coord in
            let (gx, gy) = MercatorProjection.lngLatToGlobalPixel(lng: coord.longitude, lat: coord.latitude)
            let r = Self.radiusPixels(toleranceMeters, latitude: coord.latitude)
            return isVisitedNear(gx: gx, gy: gy, radiusPixels: r)
        }
    }

    /// Fraction of a square area around `center` that is unexplored, from a coarse sample grid.
    /// Used to rank candidate detour waypoints.
    func unexploredFraction(around center: CLLocationCoordinate2D, radiusMeters: Double, gridSize: Int = 7) -> Double {
        guard !tiles.isEmpty else { return 1 }
        let (cx, cy) = MercatorProjection.lngLatToGlobalPixel(lng: center.longitude, lat: center.latitude)
        let metersPerPixel = MercatorProjection.metersPerPixel(atLatitude: center.latitude)
        let radiusPx = radiusMeters / metersPerPixel
        let step = gridSize > 1 ? (2 * radiusPx) / Double(gridSize - 1) : 0
        let tolerance = Self.radiusPixels(25, latitude: center.latitude)

        var unexplored = 0
        for j in 0..<gridSize {
            for i in 0..<gridSize {
                let gx = cx + Int(-radiusPx + Double(i) * step)
                let gy = cy + Int(-radiusPx + Double(j) * step)
                if !isVisitedNear(gx: gx, gy: gy, radiusPixels: tolerance) {
                    unexplored += 1
                }
            }
        }
        return Double(unexplored) / Double(gridSize * gridSize)
    }

    private static func radiusPixels(_ meters: Double, latitude: Double) -> Int {
        max(0, Int((meters / MercatorProjection.metersPerPixel(atLatitude: latitude)).rounded()))
    }

    // MARK: - Cache

    private func touch(_ id: Int) {
        if let index = cacheOrder.firstIndex(of: id) {
            cacheOrder.remove(at: index)
        }
        cacheOrder.append(id)
    }

    private func insert(_ tile: FOWTile, for id: Int) {
        cache[id] = tile
        cacheBytes += tile.byteCount
        cacheOrder.append(id)
        while cacheBytes > maxCacheBytes, cacheOrder.count > 1 {
            let oldest = cacheOrder.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) {
                cacheBytes -= evicted.byteCount
            }
        }
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
    }
}
