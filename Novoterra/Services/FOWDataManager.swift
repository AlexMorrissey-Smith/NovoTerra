import Foundation
import Combine
import CoreLocation
import os

/// Owns the Fog of World data pipeline: iCloud folder -> local cache -> spatial index.
@MainActor
class FOWDataManager: ObservableObject {

    private static let log = Logger(subsystem: "com.novoterra.app", category: "FOWDataManager")

    // MARK: - Published Properties

    @Published private(set) var isLoading = false
    @Published private(set) var tileCount = 0
    @Published private(set) var pendingDownloads = 0
    @Published private(set) var lastSyncDate: Date?
    @Published var error: Error?
    /// True once at least one load has finished, so routes can be scored.
    @Published private(set) var isReady = false
    /// Incremented only when the indexed tiles actually change, so the fog overlay
    /// redraws and routes are re-scored. A sync that finds nothing new leaves it alone.
    @Published private(set) var dataVersion = 0

    // MARK: - Index

    /// Shared with the route planner and fog overlay. Safe to use from any thread.
    nonisolated let spatialIndex = FOWSpatialIndex()

    private var loadTask: Task<Void, Never>?

    /// How long a sync stays fresh before returning to the app triggers another.
    static let staleInterval: TimeInterval = 10 * 60

    // MARK: - Public Interface

    /// Sync the folder into the local cache and rebuild the index.
    /// A load already in progress is cancelled and replaced.
    func loadData(from folderURL: URL) async {
        loadTask?.cancel()

        isLoading = true
        error = nil

        let task = Task { [spatialIndex] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await LocalFileCache.shared.sync(from: folderURL)
                }.value
                try Task.checkCancellation()

                self.pendingDownloads = result.pendingDownloads
                self.lastSyncDate = Date()
                guard result.changed || !self.isReady else {
                    Self.log.info("Sync found no changes")
                    return
                }

                // Building the index only decodes filenames; tiles are decompressed on demand.
                let metadata = result.files.compactMap { url -> FOWTileMetadata? in
                    guard let id = try? FOWParser.decodeFilename(url.lastPathComponent) else { return nil }
                    let (x, y) = FOWParser.tileCoordinates(from: id)
                    return FOWTileMetadata(id: id, x: x, y: y, fileURL: url)
                }
                await spatialIndex.replaceTiles(metadata)
                try Task.checkCancellation()

                self.tileCount = metadata.count
                self.isReady = true
                self.dataVersion += 1
                Self.log.info("Indexed \(metadata.count) tiles")
            } catch is CancellationError {
                return
            } catch FOWSyncError.noTilesFound {
                // The chosen folder has no tiles, so stop showing fog from any earlier folder.
                Self.log.error("No tiles found in \(folderURL.path)")
                await spatialIndex.replaceTiles([])
                self.tileCount = 0
                self.pendingDownloads = 0
                self.lastSyncDate = Date()
                self.isReady = true
                self.dataVersion += 1
                self.error = FOWSyncError.noTilesFound
            } catch {
                Self.log.error("Load failed: \(error.localizedDescription)")
                self.error = error
            }
        }
        loadTask = task
        await task.value

        // Only the most recent load clears the spinner.
        if loadTask == task {
            isLoading = false
            loadTask = nil
        }
    }

    /// Reload only if the last sync is older than `staleInterval`, or if iCloud downloads were pending.
    func refreshIfStale(from folderURL: URL) async {
        guard !isLoading else { return }
        let isStale = lastSyncDate.map { Date().timeIntervalSince($0) > Self.staleInterval } ?? true
        guard isStale || pendingDownloads > 0 else { return }
        await loadData(from: folderURL)
    }

    /// Forget all data, including the cached copies of the user's location history,
    /// for example after disconnecting the folder.
    func reset() async {
        loadTask?.cancel()
        loadTask = nil
        await spatialIndex.replaceTiles([])
        do {
            try await LocalFileCache.shared.clear()
        } catch {
            Self.log.error("Could not delete cached tiles: \(error.localizedDescription)")
        }
        isLoading = false
        isReady = false
        tileCount = 0
        pendingDownloads = 0
        lastSyncDate = nil
        error = nil
        dataVersion += 1
    }

    /// Free decompressed tiles, for example on a memory warning.
    func clearCache() async {
        await spatialIndex.clearCache()
    }
}
