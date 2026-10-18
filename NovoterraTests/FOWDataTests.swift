import XCTest
import CoreLocation
import CryptoKit
import ImageIO


/// Tests against the real Fog of World sync files in "FOW File Examples".
final class FOWDataTests: XCTestCase {

    /// Set FOW_FIXTURES_DIR to override, for example when running from a copy of this file.
    private static let fixturesURL = ProcessInfo.processInfo.environment["FOW_FIXTURES_DIR"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FOW File Examples")

    private func fixtureFiles() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixturesURL, includingPropertiesForKeys: nil)
            .filter { FOWParser.isTileFilename($0.lastPathComponent) }
        try XCTSkipIf(files.isEmpty, "No fixture files found at \(Self.fixturesURL.path)")
        return files
    }

    // MARK: - Filenames

    func testEveryFixtureFilenameDecodesToAnIDMatchingItsHashPrefix() throws {
        for url in try fixtureFiles() {
            let name = url.lastPathComponent
            let id = try FOWParser.decodeFilename(name)
            // Fog of World prefixes each filename with the first 4 hex chars of md5(id).
            let digest = Insecure.MD5.hash(data: Data(String(id).utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(String(name.prefix(4)), String(digest.prefix(4)), name)
        }
    }

    func testNonTileFilenamesAreRejected() {
        XCTAssertFalse(FOWParser.isTileFilename(".DS_Store"))
        XCTAssertFalse(FOWParser.isTileFilename("settings.json"))
        XCTAssertFalse(FOWParser.isTileFilename("abc"))
        XCTAssertFalse(FOWParser.isTileFilename("1234zzzzzz"))
    }

    // MARK: - Tiles

    func testEveryFixtureDecompressesWithAValidLayout() throws {
        for url in try fixtureFiles() {
            let tile = try FOWParser.decodeTile(Data(contentsOf: url))
            let blockRecords = tile.data.count - FOWParser.TILE_HEADER_SIZE
            XCTAssertEqual(blockRecords % FOWParser.BLOCK_SIZE, 0, "Block section isn't a whole number of records: \(url.lastPathComponent)")
        }
    }

    func testVisitedPixelIsFoundAndToleranceExtendsToNeighbours() async throws {
        let (metadata, gx, gy) = try firstVisitedPixel()
        let index = FOWSpatialIndex()
        await index.replaceTiles([metadata])

        let onPixel = MercatorProjection.globalPixelToCoordinate(x: gx, y: gy)
        let mask = await index.visitedMask(for: [onPixel], toleranceMeters: 0)
        XCTAssertEqual(mask, [true])

        // A point 30 m away counts as visited once the tolerance reaches back to the track.
        let shifted = Geo.offset(onPixel, bearingDegrees: 90, meters: 30)
        let tolerantMask = await index.visitedMask(for: [shifted], toleranceMeters: 40)
        XCTAssertEqual(tolerantMask, [true])
    }

    func testCoordinateInUnindexedTileIsNotVisited() async throws {
        let (metadata, _, _) = try firstVisitedPixel()
        let index = FOWSpatialIndex()
        await index.replaceTiles([metadata])

        // Antipode of the visited tile cannot be in the same tile.
        let tileCorner = MercatorProjection.tileToLngLat(tileX: metadata.x, tileY: metadata.y)
        let far = CLLocationCoordinate2D(latitude: -tileCorner.latitude, longitude: tileCorner.longitude > 0 ? tileCorner.longitude - 180 : tileCorner.longitude + 180)
        let mask = await index.visitedMask(for: [far], toleranceMeters: 20)
        XCTAssertEqual(mask, [false])
    }

    func testFogRendererClearsVisitedArea() async throws {
        let (metadata, gx, gy) = try firstVisitedPixel()
        let index = FOWSpatialIndex()
        await index.replaceTiles([metadata])

        // Zoom 14: one map tile spans 256 FOW pixels, so output pixels map 1:1.
        let z = 14
        let shift = 22 - z
        let png = await FogRenderer.renderTile(z: z, x: gx >> shift, y: gy >> shift, index: index)
        let source = try XCTUnwrap(png.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) })
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let alpha = try alphaValue(of: image, x: gx & 255, y: gy & 255)
        XCTAssertEqual(alpha, 0, "Visited pixel should be clear of fog")
    }

    // MARK: - Helpers

    /// First visited pixel in the fixtures, as global FOW pixel coordinates.
    private func firstVisitedPixel() throws -> (FOWTileMetadata, Int, Int) {
        for url in try fixtureFiles() {
            let id = try FOWParser.decodeFilename(url.lastPathComponent)
            let (tx, ty) = FOWParser.tileCoordinates(from: id)
            let tile = try FOWParser.decodeTile(Data(contentsOf: url))
            for by in 0..<128 {
                for bx in 0..<128 where tile.bitmapOffset(blockX: bx, blockY: by) != nil {
                    for py in 0..<64 {
                        for px in 0..<64 where tile.isVisited(blockX: bx, blockY: by, pixelX: px, pixelY: py) {
                            let gx = tx * 8192 + bx * 64 + px
                            let gy = ty * 8192 + by * 64 + py
                            return (FOWTileMetadata(id: id, x: tx, y: ty, fileURL: url), gx, gy)
                        }
                    }
                }
            }
        }
        throw XCTSkip("No visited pixels in fixtures")
    }

    private func alphaValue(of image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Draw so that pixel (x, y) from the top-left lands on the 1x1 context.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[3]
    }
}
