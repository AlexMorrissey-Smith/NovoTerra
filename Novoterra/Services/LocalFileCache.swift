import Foundation

/// Manages caching of FOW sync files to the local sandbox
/// This ensures files are available offline and avoids security scope issues with child items
actor LocalFileCache {
    
    static let shared = LocalFileCache()
    
    private init() {}
    
    // MARK: - Sync Tracking
    
    private let lastSyncKey = "LocalFileCache.lastSyncDate"
    
    /// Get the last successful sync date
    var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }
    
    /// Check if sync is stale (older than given interval)
    func isSyncStale(olderThan interval: TimeInterval = 3600) -> Bool {
        guard let lastSync = lastSyncDate else { return true }
        return Date().timeIntervalSince(lastSync) > interval
    }
    
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
    
    /// Sync files from the external source folder to the local cache
    /// - Parameter sourceFolderURL: The iCloud/External folder URL
    /// - Returns: Array of URLs to the local cached files
    func sync(from sourceFolderURL: URL) async throws -> [URL] {
        let fileManager = FileManager.default
        let cacheFolder = try getCacheFolder()
        
        // Create cache dir if needed
        if !fileManager.fileExists(atPath: cacheFolder.path) {
            try fileManager.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        }
        
        // 1. Discover source files
        // Check for "Sync" subfolder
        var effectiveSource = sourceFolderURL
        let syncSubfolder = sourceFolderURL.appendingPathComponent("Sync")
        if fileManager.fileExists(atPath: syncSubfolder.path) {
            effectiveSource = syncSubfolder
        }
        
        // Get contents with iCloud download status
        let sourceContents = try fileManager.contentsOfDirectory(
            at: effectiveSource,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey
            ],
            options: [.skipsHiddenFiles]
        )
        
        // Filter for potential tile files
        let sourceFiles = sourceContents.filter { url in
            let filename = url.lastPathComponent
            guard filename.count >= 7 else { return false }
            let ext = url.pathExtension.lowercased()
            if ["json", "plist", "txt", "log", "db", "sqlite", "ds_store"].contains(ext) {
                return false
            }
            return true
        }
        
        print("LocalFileCache: Found \(sourceFiles.count) potential tile files to sync")
        
        // 2. Sync loop - handle iCloud downloads and changed files
        var validLocalFiles: [URL] = []
        var downloadsPending = 0
        
        for sourceURL in sourceFiles {
            let filename = sourceURL.lastPathComponent
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
                    print("LocalFileCache: Triggered download for \(filename)")
                } catch {
                    print("LocalFileCache: Could not trigger download for \(filename): \(error)")
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
                print("LocalFileCache: \(filename) is still downloading, skipping")
                // IMPORTANT: If we have an existing cached copy, keep it!
                if fileManager.fileExists(atPath: destinationURL.path) {
                    validLocalFiles.append(destinationURL)
                }
                continue
            }
            
            // File is available locally (either downloaded or not in iCloud)
            if shouldCopy(source: sourceURL, destination: destinationURL) {
                // Remove existing if needed
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                
                // Copy
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                print("LocalFileCache: Synced \(filename)")
            }
            
            validLocalFiles.append(destinationURL)
        }
        
        if downloadsPending > 0 {
            print("LocalFileCache: \(downloadsPending) files pending download from iCloud")
        }
        
        // 3. Cleanup orphaned files in cache
        let cachedContents = try fileManager.contentsOfDirectory(
            at: cacheFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        
        let validFilenames = Set(validLocalFiles.map { $0.lastPathComponent })
        
        for cachedURL in cachedContents {
            if !validFilenames.contains(cachedURL.lastPathComponent) {
                try fileManager.removeItem(at: cachedURL)
                print("LocalFileCache: Removed orphaned file \(cachedURL.lastPathComponent)")
            }
        }
        
        // Update last sync timestamp
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        
        print("LocalFileCache: Sync complete - \(validLocalFiles.count) files in cache")
        
        return validLocalFiles
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
            print("LocalFileCache: Error comparing files: \(error)")
            return true // Fail safe: copy
        }
        
        return true
    }
}
