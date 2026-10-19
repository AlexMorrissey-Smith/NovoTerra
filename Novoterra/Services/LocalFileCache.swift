import Foundation
import os

/// Result of copying the FOW sync folder into the local cache.
struct FOWSyncResult: Sendable {
    /// Local copies of every tile file available right now.
    let files: [URL]
    /// Files still downloading from iCloud. They are picked up on the next sync.
    let pendingDownloads: Int
    /// True if any cached file was added, replaced or removed by this sync.
    let changed: Bool
}

enum FOWSyncError: Error, LocalizedError {
    case noTilesFound

    var errorDescription: String? {
        switch self {
        case .noTilesFound:
            return "No Fog of World tiles found in this folder. Choose the Fog of World folder in iCloud Drive."
        }
    }
}

/// Manages caching of FOW sync files to the local sandbox
/// This ensures files are available offline and avoids security scope issues with child items
actor LocalFileCache {
    
    static let shared = LocalFileCache()
    
    private init() {}

    private static let log = Logger(subsystem: "com.novoterra.app", category: "LocalFileCache")
    
    /// Get the cache folder URL
    func getCacheFolder() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("FOWCache", isDirectory: true)
    }

    /// Delete every cached tile, for example when the user disconnects their data.
    func clear() throws {
        let cacheFolder = try getCacheFolder()
        if FileManager.default.fileExists(atPath: cacheFolder.path) {
            try FileManager.default.removeItem(at: cacheFolder)
        }
    }

    /// Hidden file in the cache recording which source folder the tiles came from.
    private static let sourceMarkerName = ".source"
    
    /// Sync files from the external source folder to the local cache
    /// - Parameter sourceFolderURL: The iCloud/External folder URL
    /// - Returns: Local cached tile files plus the number of files still downloading
    func sync(from sourceFolderURL: URL) throws -> FOWSyncResult {
        let fileManager = FileManager.default
        let cacheFolder = try getCacheFolder()
        
        // 1. Discover source files.
        // Users often pick the parent "Fog of World" folder or one above it,
        // so look for the folder that actually contains tile files.
        guard let effectiveSource = Self.findTileFolder(in: sourceFolderURL) else {
            throw FOWSyncError.noTilesFound
        }

        // The cache belongs to one source folder. Switching folders starts it afresh,
        // so tiles from the previous folder never mix with the new one.
        let markerURL = cacheFolder.appendingPathComponent(Self.sourceMarkerName)
        let sourceKey = effectiveSource.standardizedFileURL.path
        var changed = false
        if (try? String(contentsOf: markerURL, encoding: .utf8)) != sourceKey {
            try clear()
            changed = true
        }

        if !fileManager.fileExists(atPath: cacheFolder.path) {
            try fileManager.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        }
        try sourceKey.write(to: markerURL, atomically: true, encoding: .utf8)

        // Get contents with iCloud download status
        let sourceContents = try fileManager.contentsOfDirectory(
            at: effectiveSource,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey
            ],
            // Not skipping hidden files: undownloaded iCloud items appear as hidden ".name.icloud" placeholders.
            options: []
        )
        
        // Keep only tile files. iCloud placeholders for files not yet downloaded are
        // hidden ".name.icloud" entries, so they are matched by their real name too.
        let sourceFiles = sourceContents.filter { url in
            FOWParser.isTileFilename(Self.realFilename(url))
        }

        Self.log.info("Found \(sourceFiles.count) tile files to sync")
        
        // 2. Sync loop - handle iCloud downloads and changed files
        var validLocalFiles: [URL] = []
        var downloadsPending = 0
        
        for listedURL in sourceFiles {
            let filename = Self.realFilename(listedURL)
            // Always address the real item, not its ".icloud" placeholder.
            let sourceURL = effectiveSource.appendingPathComponent(filename)
            let destinationURL = cacheFolder.appendingPathComponent(filename)
            
            // Check if file needs to be downloaded from iCloud first
            let resourceValues = try? sourceURL.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey
            ])
            
            let downloadStatus = resourceValues?.ubiquitousItemDownloadingStatus
            
            // If file is in iCloud but not downloaded, trigger download
            if downloadStatus == .notDownloaded {
                do {
                    try fileManager.startDownloadingUbiquitousItem(at: sourceURL)
                    downloadsPending += 1
                } catch {
                    Self.log.error("Could not trigger download for \(filename): \(error.localizedDescription)")
                }
                // IMPORTANT: If we have an existing cached copy, keep it!
                if fileManager.fileExists(atPath: destinationURL.path) {
                    validLocalFiles.append(destinationURL)
                }
                continue
            }
            
            // If file is currently downloading, skip for now but keep existing cache
            if resourceValues?.ubiquitousItemIsDownloading == true {
                downloadsPending += 1
                // IMPORTANT: If we have an existing cached copy, keep it!
                if fileManager.fileExists(atPath: destinationURL.path) {
                    validLocalFiles.append(destinationURL)
                }
                continue
            }
            
            // File is available locally (either downloaded or not in iCloud).
            // A failure here affects only this tile; keep any older cached copy and carry on.
            if shouldCopy(source: sourceURL, destination: destinationURL) {
                do {
                    let staging = cacheFolder.appendingPathComponent(".\(filename).partial")
                    try? fileManager.removeItem(at: staging)
                    try fileManager.copyItem(at: sourceURL, to: staging)
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        _ = try fileManager.replaceItemAt(destinationURL, withItemAt: staging)
                    } else {
                        try fileManager.moveItem(at: staging, to: destinationURL)
                    }
                    changed = true
                } catch {
                    try? fileManager.removeItem(at: cacheFolder.appendingPathComponent(".\(filename).partial"))
                    Self.log.error("Could not copy \(filename): \(error.localizedDescription)")
                }
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                validLocalFiles.append(destinationURL)
            }
        }
        
        // 3. Cleanup orphaned files in cache.
        let cachedContents = try fileManager.contentsOfDirectory(
            at: cacheFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        
        let validFilenames = Set(validLocalFiles.map { $0.lastPathComponent })
        
        for cachedURL in cachedContents {
            if !validFilenames.contains(cachedURL.lastPathComponent) {
                try? fileManager.removeItem(at: cachedURL)
                changed = true
            }
        }
        
        
        Self.log.info("Sync complete: \(validLocalFiles.count) files cached, \(downloadsPending) pending")

        return FOWSyncResult(files: validLocalFiles, pendingDownloads: downloadsPending, changed: changed)
    }

    /// Breadth-first search (up to 3 levels deep) for the first folder holding tile files.
    /// The "Sync" subfolder, where Fog of World keeps its data, is checked first at each level.
    private static func findTileFolder(in root: URL, maxDepth: Int = 3) -> URL? {
        let fileManager = FileManager.default
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (folder, depth) = queue.removeFirst()
            guard let contents = try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []
            ) else { continue }

            if contents.contains(where: { FOWParser.isTileFilename(realFilename($0)) }) {
                return folder
            }
            guard depth < maxDepth else { continue }
            let subfolders = contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { a, _ in a.lastPathComponent == "Sync" }
            queue.append(contentsOf: subfolders.map { ($0, depth + 1) })
        }
        return nil
    }

    /// Filename with the iCloud placeholder wrapping (".name.icloud") removed.
    private static func realFilename(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            return String(name.dropFirst().dropLast(".icloud".count))
        }
        return name
    }
    
    /// Check if we need to copy the file (missing or modified)
    private func shouldCopy(source: URL, destination: URL) -> Bool {
        let fileManager = FileManager.default
        
        // If dest doesn't exist, Copy
        if !fileManager.fileExists(atPath: destination.path) {
            return true
        }
        
        // If exists, compare mod dates and size
        do {
            let srcAttributes = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let dstAttributes = try destination.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            
            if let srcDate = srcAttributes.contentModificationDate,
               let dstDate = dstAttributes.contentModificationDate,
               let srcSize = srcAttributes.fileSize,
               let dstSize = dstAttributes.fileSize {
                
                // If sizes differ, copy (handles modified files)
                if srcSize != dstSize { return true }
                
                // If source is newer than dest (with small buffer for fs precision), copy
                if srcDate.timeIntervalSince(dstDate) > 1.0 {
                    return true
                }
                
                // Otherwise assume up to date
                return false
            }
        } catch {
            return true // Fail safe: copy
        }
        
        return true
    }
}
