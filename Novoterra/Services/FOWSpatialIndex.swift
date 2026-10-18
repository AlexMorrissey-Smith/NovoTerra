import Foundation
import CoreLocation

/// Memory-optimized spatial index for FOW data
/// Stores ONLY tile metadata, loads bitmaps on-demand to avoid RAM explosion
actor FOWSpatialIndex {
    
    // MARK: - Storage
    
    /// Sparse storage: only tracks WHICH blocks exist, not their bitmap data
    private var tileMetadata: [TileKey: FOWTileMetadata] = [:]
    
    /// Cache of recently accessed decompressed tile data
    /// Uses LRU eviction to keep memory bounded
    private var tileCache: [TileKey: Data] = [:]
    private var cacheOrder: [TileKey] = []
    private let maxCacheSize = 8  // Balance between memory usage and route calculation reliability
    
    // MARK: - Registration
    
    /// Register a tile's metadata without loading bitmap data
    func registerTile(_ metadata: FOWTileMetadata) {
        tileMetadata[metadata.tileKey] = metadata
    }
    
    /// Get count of registered tiles
    var tileCount: Int {
        tileMetadata.count
    }
    
    /// Get all registered tile metadata
    func getAllTileMetadata() -> [FOWTileMetadata] {
        Array(tileMetadata.values)
    }
    
    /// Get block data for fog rendering (uses LRU cache)
    func getBlock(for tile: FOWTileMetadata, blockX: Int, blockY: Int) async -> FOWBlock? {
        do {
            let tileData = try await loadTileData(for: tile)
            return FOWParser.loadBlock(from: tileData, blockX: blockX, blockY: blockY)
        } catch {
            print("Error loading block: \(error)")
            return nil
        }
    }
    
    // MARK: - Coordinate Checking
    
    /// Check if a coordinate has been visited
    /// JIT loads bitmap data only when needed
    func isCoordinateVisited(_ coord: CLLocationCoordinate2D) async -> Bool {
        let components = MercatorProjection.coordinateToComponents(coord)
        
        // Check if tile exists
        guard let metadata = tileMetadata[components.tileKey] else {
            return false
        }
        
        // Check if block exists in this tile
        guard metadata.existingBlockKeys.contains(components.blockKey) else {
            return false
        }
        
        // JIT load the tile data and check specific pixel
        do {
            let tileData = try await loadTileData(for: metadata)
            
            guard let block = FOWParser.loadBlock(
                from: tileData,
                blockX: components.blockX,
                blockY: components.blockY
            ) else {
                return false
            }
            
            return block.isVisited(pixelX: components.pixelX, pixelY: components.pixelY)
        } catch {
            print("Error loading tile data: \(error)")
            return false
        }
    }
    
    /// Calculate percentage of a polyline that passes through visited areas
    /// Samples at regular intervals for performance
    func visitedPercentageAlongPath(_ coordinates: [CLLocationCoordinate2D]) async -> Double {
        guard !coordinates.isEmpty else { return 0 }
        
        var visitedCount = 0
        
        for coord in coordinates {
            if await isCoordinateVisited(coord) {
                visitedCount += 1
            }
        }
        
        return Double(visitedCount) / Double(coordinates.count)
    }
    
    // MARK: - Private Helpers
    
    /// Load tile data with caching
    /// NOTE: This requires the parent folder's security scope to still be active.
    /// The stored file URLs don't have their own security scope - they inherited from parent.
    /// TODO: Need to either keep parent scope active, or store per-file bookmarks.
    private func loadTileData(for metadata: FOWTileMetadata) async throws -> Data {
        // Check cache first
        if let cached = tileCache[metadata.tileKey] {
            // Move to end of LRU order
            cacheOrder.removeAll { $0 == metadata.tileKey }
            cacheOrder.append(metadata.tileKey)
            return cached
        }
        
        // Load from disk
        // Note: The parent folder's security scope must still be active for this to work.
        // Calling startAccessingSecurityScopedResource() on child URLs fails because
        // they weren't directly user-selected via document picker.
        let url = metadata.fileURL

        // Memory-mapped read
        let compressedData = try Data(contentsOf: url)
        
        // Decompress
        let decompressedData = try FOWParser.decompressTile(compressedData)
        
        // Add to cache
        tileCache[metadata.tileKey] = decompressedData
        cacheOrder.append(metadata.tileKey)
        
        // Evict oldest if over limit
        while cacheOrder.count > maxCacheSize {
            let oldest = cacheOrder.removeFirst()
            tileCache.removeValue(forKey: oldest)
        }
        
        return decompressedData
    }
    
    /// Clear all cached data
    func clearCache() {
        let clearedCount = tileCache.count
        tileCache.removeAll()
        cacheOrder.removeAll()
        if clearedCount > 0 {
            print("FOWSpatialIndex: Cleared \(clearedCount) cached tiles to free memory")
        }
    }
}

// MARK: - Errors

enum SpatialIndexError: Error, LocalizedError {
    case securityScopeDenied
    case tileNotFound
    
    var errorDescription: String? {
        switch self {
        case .securityScopeDenied:
            return "Security scope access denied for file"
        case .tileNotFound:
            return "Tile not found in index"
        }
    }
}
