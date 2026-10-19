import Foundation
import CoreLocation
import MapKit

// MARK: - Tile Metadata
/// Index entry for one Fog of World tile file. Bitmap data is loaded on demand by FOWSpatialIndex.
struct FOWTileMetadata: Sendable {
    let id: Int        // y * 512 + x
    let x: Int         // 0-511
    let y: Int         // 0-511
    let fileURL: URL
}

// MARK: - Decoded Tile
/// A decompressed Fog of World tile: a 128x128 block index header followed by block records.
struct FOWTile: Sendable {
    let data: Data

    /// Approximate memory footprint, used for the LRU byte budget.
    var byteCount: Int { data.count }

    /// Returns the byte offset of a block's 512-byte bitmap, or nil if the block was never visited.
    func bitmapOffset(blockX: Int, blockY: Int) -> Int? {
        let headerIndex = blockX + blockY * FOWParser.TILE_WIDTH
        let byteOffset = headerIndex * 2
        guard byteOffset + 2 <= data.count else { return nil }
        let blockIdx = data.withUnsafeBytes {
            UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self))
        }
        guard blockIdx > 0 else { return nil }
        let start = FOWParser.TILE_HEADER_SIZE + Int(blockIdx - 1) * FOWParser.BLOCK_SIZE
        guard start + FOWParser.BLOCK_BITMAP_SIZE <= data.count else { return nil }
        return start
    }

    /// Whether the given pixel inside the given block is visited.
    func isVisited(blockX: Int, blockY: Int, pixelX: Int, pixelY: Int) -> Bool {
        guard let offset = bitmapOffset(blockX: blockX, blockY: blockY) else { return false }
        let byte = data[data.startIndex + offset + pixelX / 8 + pixelY * 8]
        return byte & (1 << (7 - (pixelX % 8))) != 0
    }
}

// MARK: - Travel Mode
enum TravelMode: String, CaseIterable, Identifiable, Sendable {
    case driving = "Drive"
    case cycling = "Cycle"
    case walking = "Walk"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .driving: return "car.fill"
        case .cycling: return "bicycle"
        case .walking: return "figure.walk"
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .driving: return .automobile
        case .cycling: return .cycling
        case .walking: return .walking
        }
    }

    var appleMapsMode: String {
        switch self {
        case .driving: return MKLaunchOptionsDirectionsModeDriving
        case .cycling: return MKLaunchOptionsDirectionsModeCycling
        case .walking: return MKLaunchOptionsDirectionsModeWalking
        }
    }

    var googleMapsMode: String {
        switch self {
        case .driving: return "driving"
        case .cycling: return "bicycling"
        case .walking: return "walking"
        }
    }

    /// Spacing between handoff waypoints. Shorter for slow modes so the external app
    /// can't take a shortcut that skips the unexplored section.
    var waypointSpacingMeters: Double {
        switch self {
        case .driving: return 4000
        case .cycling: return 1500
        case .walking: return 500
        }
    }
}

// MARK: - Route Option
struct RouteOption: Identifiable {
    var id = UUID()
    /// One leg for direct routes; two legs for routes forced through an unexplored waypoint.
    let legs: [MKRoute]
    let totalDistanceMeters: Double
    let expectedTravelTime: TimeInterval
    let visitedDistanceMeters: Double
    /// Full route geometry, all legs joined.
    let coordinates: [CLLocationCoordinate2D]
    /// Index in `coordinates` where the second leg starts, for routes forced through a waypoint.
    let joinIndex: Int?
    /// Filled in after ranking, relative to the fastest route found.
    var extraTimeVsFastest: TimeInterval = 0
    var extraNewDistanceVsFastest: Double = 0
    var isFastest: Bool = false

    var newDistanceMeters: Double { max(0, totalDistanceMeters - visitedDistanceMeters) }
    var visitedFraction: Double { totalDistanceMeters > 0 ? visitedDistanceMeters / totalDistanceMeters : 0 }
    var newTerritoryPercentage: Int { Int(((1 - visitedFraction) * 100).rounded()) }
    var isCompositeRoute: Bool { legs.count > 1 }

    /// Intermediate stops that make an external navigation app follow this route.
    /// Points are spread evenly by distance along the route geometry, so they sit on roads,
    /// and the forced detour point is always kept so the unexplored section isn't skipped.
    func handoffWaypoints(maxCount: Int, spacingMeters: Double) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2, maxCount > 0 else { return [] }

        var cumulative = [0.0]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            cumulative.append(cumulative.last! + Geo.distance(a, b))
        }
        let total = cumulative.last!
        guard total > 0 else { return [] }

        // Small epsilon so floating-point drift on an exact multiple doesn't add a stop.
        let sections = Int(ceil(total / spacingMeters - 0.01))
        let count = min(maxCount, max(1, sections - 1))
        var indices: [Int] = []
        var cursor = 0
        for i in 1...count {
            let target = total * Double(i) / Double(count + 1)
            while cursor < cumulative.count - 1, cumulative[cursor] < target { cursor += 1 }
            indices.append(cursor)
        }

        if let joinIndex {
            // Swap the nearest evenly spaced stop for the actual detour point.
            let nearest = indices.indices.min { abs(indices[$0] - joinIndex) < abs(indices[$1] - joinIndex) }!
            indices[nearest] = joinIndex
        }

        return Array(Set(indices)).sorted().map { coordinates[$0] }
    }
}

// MARK: - Exploration Level
/// How much extra travel time the user accepts in exchange for new territory.
enum AvoidanceLevel: String, CaseIterable, Identifiable {
    case exploration = "Exploration"
    case adventurous = "Adventurous"
    case balanced = "Balanced"

    var id: String { rawValue }

    /// Maximum travel time allowed, as a multiple of the fastest route's time.
    var maxTimeRatio: Double {
        switch self {
        case .exploration: return 2.0
        case .adventurous: return 1.5
        case .balanced: return 1.2
        }
    }

    var description: String {
        let percent = Int(((maxTimeRatio - 1) * 100).rounded())
        return "Up to \(percent)% longer than the fastest route"
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
        case .appleMaps: return 12
        case .googleMaps: return 9
        }
    }
}

// MARK: - Tile Block Pixel (Mercator breakdown)
struct TileBlockPixel: Equatable {
    let tileX, tileY: Int      // 0-511
    let blockX, blockY: Int    // 0-127
    let pixelX, pixelY: Int    // 0-63

    var tileID: Int { tileY * MercatorProjection.MAP_WIDTH + tileX }
}

// MARK: - Formatting
enum Format {
    static func distance(_ meters: Double) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let style = MeasurementFormatter()
        style.unitOptions = .naturalScale
        style.unitStyle = .short
        style.numberFormatter.maximumFractionDigits = meters >= 1000 ? 1 : 0
        return style.string(from: measurement)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}
