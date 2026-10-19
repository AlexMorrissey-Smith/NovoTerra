import Foundation
import CoreLocation

/// Converts between CLLocationCoordinate2D and FOW tile/block/pixel coordinates
/// This is the "physics engine" of the app - precision is critical
enum MercatorProjection {
    static let MAP_WIDTH = 512        // Tiles at zoom level 9
    static let TILE_WIDTH = 128       // Blocks per tile
    static let BITMAP_WIDTH = 64      // Pixels per block

    // Combined offsets for bit shifting
    private static let TILE_OFFSET = 13    // log2(128 * 64) = 13
    private static let BLOCK_OFFSET = 6    // log2(64) = 6

    /// Width of the whole world in FOW pixels (2^22). Equivalent to web-mercator zoom 22 at 1px per tile pixel.
    static let WORLD_PIXELS = MAP_WIDTH * TILE_WIDTH * BITMAP_WIDTH
    /// Equatorial circumference used by web mercator.
    private static let EARTH_CIRCUMFERENCE_METERS = 40_075_016.686

    /// Convert lat/lng to global pixel coordinates
    static func lngLatToGlobalPixel(lng: Double, lat: Double) -> (x: Int, y: Int) {
        let clampedLat = min(max(lat, -85.05112878), 85.05112878)
        let x = ((lng + 180) / 360) * Double(MAP_WIDTH)
        let latRad = clampedLat * .pi / 180
        let y = ((Double.pi - asinh(tan(latRad))) * Double(MAP_WIDTH)) / (2 * .pi)

        let xg = Int(x * Double(TILE_WIDTH * BITMAP_WIDTH))
        let yg = Int(y * Double(TILE_WIDTH * BITMAP_WIDTH))
        return (min(max(xg, 0), WORLD_PIXELS - 1), min(max(yg, 0), WORLD_PIXELS - 1))
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

    /// Ground size of one FOW pixel at the given latitude (about 9.6 m at the equator, 6 m in the UK).
    static func metersPerPixel(atLatitude lat: Double) -> Double {
        EARTH_CIRCUMFERENCE_METERS * cos(lat * .pi / 180) / Double(WORLD_PIXELS)
    }

    /// Coordinate of the centre of a global FOW pixel.
    static func globalPixelToCoordinate(x: Int, y: Int) -> CLLocationCoordinate2D {
        let world = Double(WORLD_PIXELS)
        let lng = (Double(x) + 0.5) / world * 360 - 180
        let lat = atan(sinh(.pi - 2 * .pi * (Double(y) + 0.5) / world)) * 180 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Convert tile x,y back to approximate lng/lat (north-west corner of tile)
    static func tileToLngLat(tileX: Int, tileY: Int) -> CLLocationCoordinate2D {
        let lng = (Double(tileX) / Double(MAP_WIDTH)) * 360 - 180
        let latRad = atan(sinh(.pi - (2 * .pi * Double(tileY)) / Double(MAP_WIDTH)))
        let lat = latRad * 180 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
