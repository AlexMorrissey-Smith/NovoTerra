import Foundation
import Compression

/// Parses Fog of World sync data files.
/// Format reference: fog-machine (https://github.com/CaviarChen/fog-machine).
enum FOWParser {

    // MARK: - Constants (from fog-machine analysis)
    static let FILENAME_MASK1 = "olhwjsktri"
    static let MAP_WIDTH = 512
    static let TILE_WIDTH = 128
    static let BITMAP_WIDTH = 64
    static let TILE_HEADER_SIZE = 128 * 128 * 2  // 32,768 bytes
    static let BLOCK_BITMAP_SIZE = 512
    static let BLOCK_EXTRA_DATA = 3
    static let BLOCK_SIZE = 515
    /// Largest possible decompressed tile: full header plus every block present.
    static let MAX_TILE_SIZE = TILE_HEADER_SIZE + TILE_WIDTH * TILE_WIDTH * BLOCK_SIZE

    private static let filenameEncoding: [Character: Int] = {
        var encoding: [Character: Int] = [:]
        for (i, char) in FILENAME_MASK1.enumerated() {
            encoding[char] = i
        }
        return encoding
    }()

    // MARK: - Filename Decoding

    /// Whether a filename looks like a FOW tile file: [4-char hash][masked digits][2-char suffix].
    static func isTileFilename(_ filename: String) -> Bool {
        (try? decodeFilename(filename)) != nil
    }

    /// Extract tile ID from masked filename
    static func decodeFilename(_ filename: String) throws -> Int {
        guard filename.count >= 7, !filename.contains(".") else {
            throw FOWParserError.invalidFilename(filename)
        }
        let maskedPart = filename.dropFirst(4).dropLast(2)

        var id = 0
        for char in maskedPart {
            guard let digit = filenameEncoding[char] else {
                throw FOWParserError.invalidFilename(filename)
            }
            id = id * 10 + digit
        }

        guard id < MAP_WIDTH * MAP_WIDTH else {
            throw FOWParserError.invalidFilename(filename)
        }
        return id
    }

    /// Get tile x,y coordinates from ID
    static func tileCoordinates(from id: Int) -> (x: Int, y: Int) {
        (id % MAP_WIDTH, id / MAP_WIDTH)
    }

    // MARK: - Decompression

    /// Decompress a tile file and validate its layout.
    /// FOW files use the zlib container (2-byte header + raw DEFLATE + Adler-32).
    /// Apple's COMPRESSION_ZLIB decodes raw DEFLATE, so the wrapper is stripped first.
    static func decodeTile(_ compressedData: Data) throws -> FOWTile {
        let data = try decompress(compressedData)
        guard data.count >= TILE_HEADER_SIZE else {
            throw FOWParserError.invalidTileData
        }
        return FOWTile(data: data)
    }

    static func decompress(_ compressedData: Data) throws -> Data {
        var payload = compressedData
        if compressedData.count > 6,
           compressedData[compressedData.startIndex] & 0x0F == 0x08,  // CM = deflate
           (UInt16(compressedData[compressedData.startIndex]) << 8 | UInt16(compressedData[compressedData.startIndex + 1])) % 31 == 0 {
            payload = compressedData.dropFirst(2).dropLast(4)
        }

        // Start from a typical ratio and grow until the output no longer fills the buffer.
        var capacity = min(MAX_TILE_SIZE, max(256 * 1024, payload.count * 16))
        while true {
            let result = try decode(payload, capacity: capacity)
            if result.count < capacity || capacity >= MAX_TILE_SIZE {
                return result
            }
            capacity = min(MAX_TILE_SIZE, capacity * 2)
        }
    }

    private static func decode(_ payload: Data, capacity: Int) throws -> Data {
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, capacity, srcBase, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw FOWParserError.decompressionFailed }
        output.count = written
        return output
    }
}

// MARK: - Errors

enum FOWParserError: Error, LocalizedError {
    case invalidFilename(String)
    case decompressionFailed
    case invalidTileData

    var errorDescription: String? {
        switch self {
        case .invalidFilename(let name):
            return "Invalid FOW filename: \(name)"
        case .decompressionFailed:
            return "Failed to decompress tile data"
        case .invalidTileData:
            return "Invalid tile data format"
        }
    }
}
