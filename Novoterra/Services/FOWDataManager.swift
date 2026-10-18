import Foundation
import Combine
import CoreLocation

/// Manages loading and indexing of FOW data
@MainActor
class FOWDataManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isLoading: Bool = false
    @Published var loadingProgress: Double = 0
    @Published var tileCount: Int = 0
    @Published var error: Error?
    @Published var isReady: Bool = false
    
    // MARK: - Private Properties
    
    private let spatialIndex = FOWSpatialIndex()
    private var loadTask: Task<Void, Never>?
    
    // MARK: - Public Interface
    
    /// Load FOW data from the given folder URL
    func loadData(from folderURL: URL) async {
        // Cancel any existing load
        loadTask?.cancel()
        
        isLoading = true
        loadingProgress = 0
        error = nil
        isReady = false
        
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performLoad(from: folderURL)
        }
        
        await loadTask?.value
    }
    
    /// Check if a coordinate is visited
    func isCoordinateVisited(_ coord: CLLocationCoordinate2D) async -> Bool {
        await spatialIndex.isCoordinateVisited(coord)
    }
    
    /// Calculate visited percentage along a path
    func visitedPercentageAlongPath(_ coordinates: [CLLocationCoordinate2D]) async -> Double {
        await spatialIndex.visitedPercentageAlongPath(coordinates)
    }
    
    /// Clear all cached data
    func clearCache() async {
        await spatialIndex.clearCache()
    }
    
    /// Get all visited tile metadata (for fog rendering)
    func getAllVisitedTiles() async -> [FOWTileMetadata] {
        await spatialIndex.getAllTileMetadata()
    }
    
    /// Get block data for fog rendering (uses LRU cache in spatial index)
    func getBlock(for tile: FOWTileMetadata, blockX: Int, blockY: Int) async -> FOWBlock? {
        await spatialIndex.getBlock(for: tile, blockX: blockX, blockY: blockY)
    }
    
    // MARK: - Private Loading
    
    nonisolated private func performLoad(from folderURL: URL) async {
        do {
            // 1. Sync to local cache (incremental)
            // This handles "Sync" subfolder logic and security scoping internally
            await MainActor.run {
                self.loadingProgress = 0.05 // Tiny progress for sync start
            }
            
            let localFiles = try await LocalFileCache.shared.sync(from: folderURL)
            
            print("FOWDataManager: Synced \(localFiles.count) files to local cache")
            
            // 2. Filter to tile files using mask character validation
            let mask1Chars = Set("olhwjsktri")
            let tileFiles = localFiles.filter { url in
                let filename = url.lastPathComponent
                guard filename.count >= 7 else { return false }
                
                // Skip known non-tile extensions
                let ext = url.pathExtension.lowercased()
                if ["json", "plist", "txt", "log", "db", "sqlite", "ds_store"].contains(ext) {
                    return false
                }
                
                // Check if middle portion contains mask characters
                let middlePart = String(filename.dropFirst(4).dropLast(2))
                return middlePart.allSatisfy { mask1Chars.contains($0) }
            }
            
            print("FOWDataManager: Found \(tileFiles.count) tile files after filtering")
            
            let totalFiles = tileFiles.count
            var processedFiles = 0
            
            await MainActor.run {
                self.tileCount = 0
            }
            
            // Process each tile file
            for fileURL in tileFiles {
                // Check for cancellation
                if Task.isCancelled { break }
                
                do {
                    // Parse header only (not full bitmap data)
                    let metadata = try await parseHeaderOnly(fileURL: fileURL)
                    
                    if let metadata = metadata {
                        await spatialIndex.registerTile(metadata)
                        
                        await MainActor.run {
                            self.tileCount += 1
                        }
                    }
                    
                } catch {
                    // Log but continue with other files
                    print("Failed to parse \(fileURL.lastPathComponent): \(error)")
                }
                
                processedFiles += 1
                
                // Update progress
                let progress = Double(processedFiles) / Double(totalFiles)
                await MainActor.run {
                    self.loadingProgress = progress
                }
            }
            
            await MainActor.run {
                self.isLoading = false
                self.isReady = true
            }
            
        } catch {
            await MainActor.run {
                self.error = error
                self.isLoading = false
            }
        }
    }
    
    /// Parse tile file header to extract block keys (memory-efficient: discards decompressed data after parsing)
    nonisolated private func parseHeaderOnly(fileURL: URL) async throws -> FOWTileMetadata? {
        let filename = fileURL.lastPathComponent
        
        // Decode tile ID from filename
        let tileId = try FOWParser.decodeFilename(filename)
        let (x, y) = FOWParser.tileCoordinates(from: tileId)
        
        // Read and decompress temporarily just to parse header
        // Note: Parent folder's security scope covers child files, no need to call
        // startAccessingSecurityScopedResource() here - it would fail on child URLs
        let compressedData = try Data(contentsOf: fileURL)
        let decompressedData = try FOWParser.decompressTile(compressedData)
        
        // Parse header to get block keys
        let blockKeys = FOWParser.parseHeader(decompressedData)
        
        // decompressedData is released here - will be reloaded on-demand via FOWSpatialIndex
        
        guard !blockKeys.isEmpty else {
            return nil  // Empty tile, skip
        }
        
        return FOWTileMetadata(
            id: tileId,
            x: x,
            y: y,
            filename: filename,
            fileURL: fileURL,
            existingBlockKeys: blockKeys
        )
    }
}
