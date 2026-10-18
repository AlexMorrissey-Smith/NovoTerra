import Foundation
import CoreLocation

/// Converts between CLLocationCoordinate2D and FOW tile/block/pixel coordinates
/// This is the "physics engine" of the app - precision is critical
struct MercatorProjection {
    static let MAP_WIDTH = 512        // Tiles at zoom level 9
    static let TILE_WIDTH = 128       // Blocks per tile
    static let BITMAP_WIDTH = 64      // Pixels per block
    
    // Combined offsets for bit shifting
    private static let TILE_OFFSET = 13    // log2(128 * 64) = 13
    private static let BLOCK_OFFSET = 6    // log2(64) = 6
    
    /// Convert lat/lng to global pixel coordinates
    static func lngLatToGlobalPixel(lng: Double, lat: Double) -> (x: Int, y: Int) {
        let x = ((lng + 180) / 360) * Double(MAP_WIDTH)
        let latRad = lat * .pi / 180
        let y = ((Double.pi - asinh(tan(latRad))) * Double(MAP_WIDTH)) / (2 * .pi)
        
        let xg = Int(x * Double(TILE_WIDTH * BITMAP_WIDTH))
        let yg = Int(y * Double(TILE_WIDTH * BITMAP_WIDTH))
        return (xg, yg)
    }
    
    /// Break down global pixel to tile/block/bit coordinates
    static func globalPixelToComponents(_ gx: Int, _ gy: Int) -> TileBlockPixel {
        let tileX = gx >> TILE_OFFSET
        let tileY = gy >> TILE_OFFSET
        
        let blockX = (gx >> BLOCK_OFFSET) & 0x7F
        let blockY = (gy >> BLOCK_OFFSET) & 0x7F
        
        let pixelX = gx & 0x3F
        let pixelY = gy & 0x3F
        
        return TileBlockPixel(
            tileX: tileX, tileY: tileY,
            blockX: blockX, blockY: blockY,
            pixelX: pixelX, pixelY: pixelY
        )
    }
    
    /// Convenience: coordinate to full breakdown
    static func coordinateToComponents(_ coord: CLLocationCoordinate2D) -> TileBlockPixel {
        let (gx, gy) = lngLatToGlobalPixel(lng: coord.longitude, lat: coord.latitude)
        return globalPixelToComponents(gx, gy)
    }
    
    /// Convert tile x,y back to approximate lng/lat (center of tile)
    static func tileToLngLat(tileX: Int, tileY: Int) -> CLLocationCoordinate2D {
        let lng = (Double(tileX) / Double(MAP_WIDTH)) * 360 - 180
        let latRad = atan(sinh(.pi - (2 * .pi * Double(tileY)) / Double(MAP_WIDTH)))
        let lat = latRad * 180 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
