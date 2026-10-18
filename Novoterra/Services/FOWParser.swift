import Foundation
import Compression

/// Parses Fog of World sync data files
/// IMPORTANT: All decompression and parsing MUST run on background thread
actor FOWParser {
    
    // MARK: - Constants (from fog-machine analysis)
    static let FILENAME_MASK1 = "olhwjsktri"
    static let FILENAME_MASK2 = "eizxdwknmo"
    static let MAP_WIDTH = 512
    static let TILE_WIDTH = 128
    static let BITMAP_WIDTH = 64
    static let TILE_HEADER_SIZE = 128 * 128 * 2  // 32,768 bytes
    static let BLOCK_BITMAP_SIZE = 512
    static let BLOCK_EXTRA_DATA = 3
    static let BLOCK_SIZE = 515
    
    // Build filename encoding lookup
    private static let filenameEncoding: [Character: Int] = {
        var encoding: [Character: Int] = [:]
        for (i, char) in FILENAME_MASK1.enumerated() {
            encoding[char] = i
        }
        return encoding
    }()
    
    // MARK: - Filename Decoding
    
    /// Extract tile ID from masked filename
    /// Filename format: [4-char MD5][masked digits][2-char suffix]
    static func decodeFilename(_ filename: String) throws -> Int {
        // Skip first 4 chars (MD5 hash) and last 2 chars (suffix)
        let maskedPart = String(filename.dropFirst(4).dropLast(2))
        
        var digits: [Int] = []
        for char in maskedPart {
            guard let digit = filenameEncoding[char] else {
                throw FOWParserError.invalidFilename(filename)
            }
            digits.append(digit)
        }
        
        guard let id = Int(digits.map { String($0) }.joined()) else {
            throw FOWParserError.invalidFilename(filename)
        }
        
        return id
    }
    
    /// Get tile x,y coordinates from ID
    static func tileCoordinates(from id: Int) -> (x: Int, y: Int) {
        let x = id % MAP_WIDTH
        let y = id / MAP_WIDTH
        return (x, y)
    }
    
    // MARK: - Decompression
    
    /// Decompress zlib/DEFLATE data
    /// FOW files use ZLIB format (78 xx header + raw DEFLATE + Adler-32 checksum)
    /// Apple's COMPRESSION_ZLIB expects raw DEFLATE, so we strip the wrapper
    static func decompressTile(_ compressedData: Data) throws -> Data {
        // Use Apple's low-level Compression framework
        // Dynamic buffer sizing: estimate 10x compression ratio, min 256KB, cap at 5MB
        // Falls back to larger buffer if initial attempt fails
        let estimatedSize = max(256 * 1024, min(5 * 1024 * 1024, compressedData.count * 10))
        
        // Try with estimated size first
        if let result = try? decompressWithBufferSize(compressedData, bufferSize: estimatedSize) {
            return result
        }
        
        // Fallback to larger buffer (10MB) if estimated size was too small
        let fallbackSize = 10 * 1024 * 1024
        return try decompressWithBufferSize(compressedData, bufferSize: fallbackSize)
    }
    
    private static func decompressWithBufferSize(_ compressedData: Data, bufferSize: Int) throws -> Data {
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }
        let destinationSize = bufferSize
        
        // Check for ZLIB header (78 xx) and strip wrapper if present
        // ZLIB format: 2-byte header + raw DEFLATE + 4-byte Adler-32 checksum
        var dataToDecompress = compressedData
        let isZlibWrapped = compressedData.count > 6 && 
                            compressedData[0] == 0x78 && 
                            (compressedData[1] == 0x01 || // No compression
                             compressedData[1] == 0x5E || // Fast compression
                             compressedData[1] == 0x9C || // Default compression  
                             compressedData[1] == 0xDA)   // Best compression
        
        if isZlibWrapped {
            // Strip 2-byte ZLIB header and 4-byte Adler-32 checksum
            dataToDecompress = compressedData.dropFirst(2).dropLast(4)
        }
        
        return try dataToDecompress.withUnsafeBytes { sourceBuffer in
            guard let sourcePointer = sourceBuffer.baseAddress?.bindMemory(to: UInt8.self, capacity: sourceBuffer.count) else {
                throw FOWParserError.invalidTileData
            }
            
            // Decompress raw DEFLATE data
            let decompressedSize = compression_decode_buffer(
                destinationBuffer,
                destinationSize,
                sourcePointer,
                sourceBuffer.count,
                nil,
                COMPRESSION_ZLIB
            )
            
            if decompressedSize > 0 {
                return Data(bytes: destinationBuffer, count: decompressedSize)
            }
            
            // If stripping wrapper failed, try with original data as fallback
            if isZlibWrapped {
                let fallbackResult = compressedData.withUnsafeBytes { fallbackBuffer -> Data? in
                    guard let fallbackPointer = fallbackBuffer.baseAddress?.bindMemory(to: UInt8.self, capacity: fallbackBuffer.count) else {
                        return nil
                    }
                    
                    let fallbackSize = compression_decode_buffer(
                        destinationBuffer,
                        destinationSize,
                        fallbackPointer,
                        fallbackBuffer.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                    
                    if fallbackSize > 0 {
                        return Data(bytes: destinationBuffer, count: fallbackSize)
                    }
                    return nil
                }
                
                if let result = fallbackResult {
                    return result
                }
            }
            
            print("Decompression failed. First 16 bytes: \(compressedData.prefix(16).map { String(format: "%02hhx", $0) }.joined(separator: " "))")
            throw FOWParserError.decompressionFailed
        }
    }
        


    
    // MARK: - Header Parsing (Metadata Only)
    
    /// Parse tile header to extract which blocks exist
    /// Does NOT load bitmap data - that's loaded JIT
    static func parseHeader(_ decompressedData: Data) -> Set<BlockKey> {
        var existingBlocks = Set<BlockKey>()
        
        let header = decompressedData.prefix(Self.TILE_HEADER_SIZE)
        
        header.withUnsafeBytes { buffer in
            // Ensure we have enough data and it's aligned properly
            guard buffer.count >= Self.TILE_HEADER_SIZE else { return }
            
            let uint16Buffer = buffer.bindMemory(to: UInt16.self)
            let limit = min(uint16Buffer.count, Self.TILE_WIDTH * Self.TILE_WIDTH)
            
            for i in 0..<limit {
                let blockIdx = UInt16(littleEndian: uint16Buffer[i])
                if blockIdx > 0 {
                    let blockX = i % Self.TILE_WIDTH
                    let blockY = i / Self.TILE_WIDTH
                    existingBlocks.insert("\(blockX)-\(blockY)")
                }
            }
        }
        
        return existingBlocks
    }
    
    // MARK: - Block Loading (JIT)
    
    /// Load a specific block's bitmap data from decompressed tile
    static func loadBlock(from decompressedData: Data, blockX: Int, blockY: Int) -> FOWBlock? {
        let headerIndex = blockX + blockY * Self.TILE_WIDTH
        
        // Read block index from header
        let blockIdx: UInt16 = decompressedData.withUnsafeBytes { buffer in
            let uint16Buffer = buffer.bindMemory(to: UInt16.self)
            return UInt16(littleEndian: uint16Buffer[headerIndex])
        }
        
        guard blockIdx > 0 else { return nil }
        
        // Calculate offset in data
        let startOffset = Self.TILE_HEADER_SIZE + Int(blockIdx - 1) * Self.BLOCK_SIZE
        let endOffset = startOffset + Self.BLOCK_BITMAP_SIZE
        
        guard endOffset <= decompressedData.count else { return nil }
        
        let bitmapData = decompressedData[startOffset..<endOffset]
        
        return FOWBlock(x: blockX, y: blockY, bitmap: Data(bitmapData))
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
