import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Manages access to the Fog of World sync folder in iCloud Drive
@MainActor
class iCloudFileManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var syncFolderURL: URL?
    @Published var isAccessGranted: Bool = false
    @Published var tileFileURLs: [URL] = []
    @Published var isLoading: Bool = false
    @Published var isSyncing: Bool = false
    @Published var error: Error?
    @Published var lastSyncDate: Date?
    
    // MARK: - Private Properties
    
    private let bookmarkKey = "NovoterraFOWSyncFolderBookmark"
    private var syncTimer: Timer?
    
    // MARK: - Bookmark Management
    
    /// Restore previously saved bookmark on app launch
    func restoreBookmark() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }
        
        do {
            var isStale = false
            // iOS uses empty options (security scope is implicit for document picker URLs)
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                // Re-save the bookmark
                try saveBookmark(for: url)
            }
            
            // Start accessing
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to start accessing security-scoped resource")
                return nil
            }
            
            syncFolderURL = url
            isAccessGranted = true
            return url
            
        } catch {
            print("Failed to restore bookmark: \(error)")
            self.error = error
            return nil
        }
    }
    
    /// Save security-scoped bookmark for future access
    func saveBookmark(for url: URL) throws {
        // iOS uses empty options (security scope is implicit)
        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
    }
    
    /// Handle folder selection from document picker
    func handleFolderSelection(_ url: URL) async {
        // Start security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            error = FileAccessError.securityScopeDenied
            return
        }
        
        do {
            // Save bookmark for future launches
            try saveBookmark(for: url)
            
            syncFolderURL = url
            isAccessGranted = true
            
            // Discover tile files
            await discoverTileFiles()
            
        } catch {
            self.error = error
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    // MARK: - File Discovery
    
    /// Discover all FOW tile files in the sync folder
    func discoverTileFiles() async {
        guard let folderURL = syncFolderURL else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let fileManager = FileManager.default
            
            // FOW stores files in a "Sync" subfolder
            // Check both the selected folder and Sync subfolder
            var searchURL = folderURL
            let syncSubfolder = folderURL.appendingPathComponent("Sync")
            
            if fileManager.fileExists(atPath: syncSubfolder.path) {
                searchURL = syncSubfolder
                print("Found Sync subfolder, searching there")
            }
            
            let contents = try fileManager.contentsOfDirectory(
                at: searchURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            
            print("Found \(contents.count) items in folder")
            
            // FOW tile files:
            // - Have no extension (or might have none detected)
            // - Are not directories
            // - Contain characters from FILENAME_MASK1 ("olhwjsktri")
            let mask1Chars = Set("olhwjsktri")
            
            tileFileURLs = contents.filter { url in
                let filename = url.lastPathComponent
                
                // Skip directories
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    return false
                }
                
                // Skip files with common extensions (not FOW tiles)
                let ext = url.pathExtension.lowercased()
                if ["json", "plist", "txt", "log", "db", "sqlite"].contains(ext) {
                    return false
                }
                
                // Should have at least 7 chars
                guard filename.count >= 7 else { return false }
                
                // Check if middle portion contains mask characters
                // FOW filenames: [4-char hash][masked digits][2-char suffix]
                let middlePart = String(filename.dropFirst(4).dropLast(2))
                let hasMaskChars = middlePart.allSatisfy { mask1Chars.contains($0) }
                
                if hasMaskChars {
                    print("Valid tile file: \(filename)")
                }
                
                return hasMaskChars
            }
            
            print("Discovered \(tileFileURLs.count) tile files")
            
        } catch {
            self.error = error
            print("Failed to discover tile files: \(error)")
        }
    }
    
    /// Read file data with proper security scope handling
    func coordinatedRead(url: URL) async throws -> Data {
        guard url.startAccessingSecurityScopedResource() else {
            throw FileAccessError.securityScopeDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        // Use memory-mapped access for large files
        return try Data(contentsOf: url)
    }
    
    // MARK: - Cleanup
    
    /// Stop accessing security-scoped resources
    func cleanup() {
        stopPeriodicSync()
        if let url = syncFolderURL {
            url.stopAccessingSecurityScopedResource()
        }
        syncFolderURL = nil
        isAccessGranted = false
    }
    
    // MARK: - Periodic Sync
    
    /// Start periodic sync timer (default: every 1 hour)
    func startPeriodicSync(interval: TimeInterval = 3600) {
        stopPeriodicSync()
        
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncFilesIfNeeded()
            }
        }
        
        print("iCloudFileManager: Started periodic sync (interval: \(Int(interval))s)")
    }
    
    /// Stop periodic sync timer
    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    /// Sync files if needed (stale or first sync)
    func syncFilesIfNeeded(staleInterval: TimeInterval = 3600) async {
        guard isAccessGranted, let folderURL = syncFolderURL else { return }
        
        // Check if sync is stale
        let isStale = await LocalFileCache.shared.isSyncStale(olderThan: staleInterval)
        
        guard isStale else {
            print("iCloudFileManager: Sync not needed, last sync is recent")
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        print("iCloudFileManager: Starting periodic sync...")
        
        do {
            let _ = try await LocalFileCache.shared.sync(from: folderURL)
            lastSyncDate = await LocalFileCache.shared.lastSyncDate
            print("iCloudFileManager: Periodic sync complete")
        } catch {
            print("iCloudFileManager: Periodic sync failed: \(error)")
            self.error = error
        }
    }
    
    /// Force a sync now (for manual refresh button)
    func syncNow() async {
        guard isAccessGranted, let folderURL = syncFolderURL else { return }
        
        isSyncing = true
        defer { isSyncing = false }
        
        print("iCloudFileManager: Manual sync triggered...")
        
        do {
            let _ = try await LocalFileCache.shared.sync(from: folderURL)
            lastSyncDate = await LocalFileCache.shared.lastSyncDate
        } catch {
            print("iCloudFileManager: Manual sync failed: \(error)")
            self.error = error
        }
    }
    
    deinit {
        // Note: deinit may not run on MainActor, be careful
        // Cleanup is handled explicitly via cleanup()
    }
}

// MARK: - Errors

enum FileAccessError: Error, LocalizedError {
    case securityScopeDenied
    case folderNotFound
    case readFailed
    
    var errorDescription: String? {
        switch self {
        case .securityScopeDenied:
            return "Access denied. Please grant permission to the Fog of World sync folder."
        case .folderNotFound:
            return "Fog of World sync folder not found."
        case .readFailed:
            return "Failed to read file data."
        }
    }
}

// MARK: - Document Picker Helper

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) async -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) async -> Void
        
        init(onPick: @escaping (URL) async -> Void) {
            self.onPick = onPick
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            Task {
                await onPick(url)
            }
        }
    }
}
