import Foundation
import MapKit
import ImageIO
import UniformTypeIdentifiers

/// Map tile overlay that draws fog everywhere except where the user has been.
final class FogTileOverlay: MKTileOverlay {
    let index: FOWSpatialIndex

    init(index: FOWSpatialIndex) {
        self.index = index
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: FogRenderer.tilePixels, height: FogRenderer.tilePixels)
        // Below zoom 6 a single map tile spans hundreds of FOW tiles; leave the world view clear.
        minimumZ = 6
        maximumZ = 22
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let index = index
        Task.detached(priority: .utility) {
            let data = await FogRenderer.renderTile(z: path.z, x: path.x, y: path.y, index: index)
            result(data, nil)
        }
    }
}

/// Rasterises FOW visited pixels into map tiles.
enum FogRenderer {
    static let tilePixels = 256
    private static let tileShift = 8  // log2(tilePixels)
    private static let worldShift = 22  // log2(MercatorProjection.WORLD_PIXELS)
    private static let fogAlpha: UInt8 = 150
    private static let fogRGB: (UInt8, UInt8, UInt8) = (18, 22, 36)

    private static let solidFogTile: Data? = makePNG(alpha: [UInt8](repeating: fogAlpha, count: tilePixels * tilePixels))

    /// PNG for one web-mercator map tile.
    static func renderTile(z: Int, x: Int, y: Int, index: FOWSpatialIndex) async -> Data? {
        guard z <= worldShift else { return nil }
        let spanShift = worldShift - z              // log2(FOW pixels per map tile side)
        let originX = x << spanShift
        let originY = y << spanShift
        let span = 1 << spanShift
        let outShift = spanShift - tileShift        // log2(FOW pixels per output pixel); negative when zoomed in past FOW resolution

        let firstTileX = originX >> 13, lastTileX = (originX + span - 1) >> 13
        let firstTileY = originY >> 13, lastTileY = (originY + span - 1) >> 13

        var alpha: [UInt8]?
        for tileY in firstTileY...lastTileY {
            for tileX in firstTileX...lastTileX {
                let id = tileY * MercatorProjection.MAP_WIDTH + tileX
                guard await index.hasTile(id: id), let tile = await index.tile(id: id) else { continue }
                if alpha == nil {
                    alpha = [UInt8](repeating: fogAlpha, count: tilePixels * tilePixels)
                }
                clearVisited(in: tile, tileX: tileX, tileY: tileY, originX: originX, originY: originY,
                             span: span, outShift: outShift, alpha: &alpha!)
            }
        }

        guard let alpha else { return solidFogTile }
        return makePNG(alpha: alpha)
    }

    /// Set alpha to zero for every output pixel that covers a visited FOW pixel.
    private static func clearVisited(
        in tile: FOWTile, tileX: Int, tileY: Int,
        originX: Int, originY: Int, span: Int, outShift: Int,
        alpha: inout [UInt8]
    ) {
        let tileOriginX = tileX << 13
        let tileOriginY = tileY << 13

        // Only blocks overlapping this map tile.
        let localMinX = max(0, originX - tileOriginX), localMaxX = min(8191, originX + span - 1 - tileOriginX)
        let localMinY = max(0, originY - tileOriginY), localMaxY = min(8191, originY + span - 1 - tileOriginY)
        guard localMinX <= localMaxX, localMinY <= localMaxY else { return }

        func clear(globalX gx: Int, globalY gy: Int) {
            let dx = gx - originX, dy = gy - originY
            if outShift >= 0 {
                let ox = dx >> outShift, oy = dy >> outShift
                alpha[oy * tilePixels + ox] = 0
            } else {
                let size = 1 << -outShift
                let ox = dx << -outShift, oy = dy << -outShift
                for row in oy..<(oy + size) {
                    let base = row * tilePixels
                    for col in ox..<(ox + size) { alpha[base + col] = 0 }
                }
            }
        }

        tile.data.withUnsafeBytes { raw in
            for blockY in (localMinY >> 6)...(localMaxY >> 6) {
                for blockX in (localMinX >> 6)...(localMaxX >> 6) {
                    guard let offset = tile.bitmapOffset(blockX: blockX, blockY: blockY) else { continue }
                    let blockOriginX = tileOriginX + blockX * 64
                    let blockOriginY = tileOriginY + blockY * 64

                    // Zoomed far out: a whole block is smaller than one output pixel.
                    if outShift >= 6 {
                        clear(globalX: blockOriginX, globalY: blockOriginY)
                        continue
                    }

                    for row in 0..<64 {
                        let gy = blockOriginY + row
                        guard gy >= originY, gy < originY + span else { continue }
                        for byteIndex in 0..<8 {
                            let byte = raw[offset + row * 8 + byteIndex]
                            guard byte != 0 else { continue }
                            for bit in 0..<8 where byte & (1 << (7 - bit)) != 0 {
                                let gx = blockOriginX + byteIndex * 8 + bit
                                guard gx >= originX, gx < originX + span else { continue }
                                clear(globalX: gx, globalY: gy)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func makePNG(alpha: [UInt8]) -> Data? {
        let count = tilePixels * tilePixels
        var rgba = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count {
            let a = alpha[i]
            guard a > 0 else { continue }
            // Premultiplied alpha.
            rgba[i * 4] = UInt8(Int(fogRGB.0) * Int(a) / 255)
            rgba[i * 4 + 1] = UInt8(Int(fogRGB.1) * Int(a) / 255)
            rgba[i * 4 + 2] = UInt8(Int(fogRGB.2) * Int(a) / 255)
            rgba[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: tilePixels, height: tilePixels,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tilePixels * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
