import Foundation
import CoreLocation

// MARK: - Tile and Block Keys
typealias TileKey = String
typealias BlockKey = String

// MARK: - FOW Tile Metadata
/// Stores metadata for FOW tiles - decompressed data is loaded on-demand via FOWSpatialIndex
struct FOWTileMetadata {
    let id: Int
    let x: Int  // 0-511
    let y: Int  // 0-511
    let filename: String
    let fileURL: URL
    let existingBlockKeys: Set<BlockKey>  // Which blocks exist in this tile
    
    var tileKey: TileKey { "\(x)-\(y)" }
}

// MARK: - FOW Block
/// A 64x64 bitmap block - loaded JIT from disk
struct FOWBlock {
    let x: Int  // 0-127 within tile
    let y: Int  // 0-127 within tile
    let bitmap: Data  // 512 bytes = 64x64 bits
    
    /// Check if a specific pixel is visited
    func isVisited(pixelX: Int, pixelY: Int) -> Bool {
        guard pixelX >= 0, pixelX < 64, pixelY >= 0, pixelY < 64 else { return false }
        let bitOffset = 7 - (pixelX % 8)
        let byteIndex = (pixelX / 8) + (pixelY * 8)
        guard byteIndex < bitmap.count else { return false }
        return (bitmap[byteIndex] & (1 << bitOffset)) != 0
    }
}

// MARK: - Route Option
struct RouteOption: Identifiable {
    let id: UUID
    let route: Any  // MKRoute in actual implementation (first leg for composite routes)
    var secondLegRoute: Any?  // Optional second leg for composite routes (origin→waypoint→destination)
    let avoidanceScore: Double  // 0.0 = all new, 1.0 = all traveled
    var avoidanceLevel: AvoidanceLevel
    let totalDistanceMeters: Double
    let expectedTravelTime: TimeInterval // Total duration in seconds
    let visitedDistanceMeters: Double
    let keyWaypoints: [CLLocationCoordinate2D]
    var waypointNames: [String?] = []  // Pre-fetched async, may be nil
    
    var newDistanceMeters: Double { totalDistanceMeters - visitedDistanceMeters }
    var newTerritoryPercentage: Int { Int((1 - avoidanceScore) * 100) }
    
    /// Whether this is a composite route with two legs
    var isCompositeRoute: Bool { secondLegRoute != nil }
}

// MARK: - Avoidance Level
enum AvoidanceLevel: String, CaseIterable, Identifiable {
    case exploration = "Exploration"
    case adventurous = "Adventurous"
    case balanced = "Balanced"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .exploration: return "Completely new tracks"
        case .adventurous: return "Mostly new paths"
        case .balanced: return "Mix of old and new"
        }
    }
    
    var threshold: Double {
        switch self {
        case .exploration: return 0.15 // Expanded to allow more routes
        case .adventurous: return 0.50 // ~50%+ new
        case .balanced: return 1.0     // Show all
        }
    }
}

// MARK: - Navigation App Preference
enum NavigationAppPreference: String, CaseIterable, Identifiable {
    case showBoth = "Show Both"
    case appleMaps = "Apple Maps"
    case googleMaps = "Google Maps"
    
    var id: String { rawValue }
}

// MARK: - Route Sorting Preference
enum RouteSortingPreference: String, CaseIterable, Identifiable {
    case newDistance = "New Distance"
    case unexploredPercentage = "% Unexplored"
    
    var id: String { rawValue }
}

// MARK: - Navigation App (for handoff)
enum NavigationApp: String, CaseIterable, Identifiable {
    case appleMaps = "Apple Maps"
    case googleMaps = "Google Maps"
    
    var id: String { rawValue }
    
    var maxWaypoints: Int {
        switch self {
        case .appleMaps: return 25  // Increased for better route fidelity
        case .googleMaps: return 10
        }
    }
}

// MARK: - Tile Block Pixel (Mercator breakdown)
struct TileBlockPixel {
    let tileX, tileY: Int      // 0-511
    let blockX, blockY: Int    // 0-127
    let pixelX, pixelY: Int    // 0-63
    
    var tileKey: TileKey { "\(tileX)-\(tileY)" }
    var blockKey: BlockKey { "\(blockX)-\(blockY)" }
}
