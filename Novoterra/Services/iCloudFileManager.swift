import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Manages access to the Fog of World sync folder in iCloud Drive
@MainActor
class iCloudFileManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var syncFolderURL: URL?
    @Published var isAccessGranted: Bool = false
    @Published var error: Error?
    
    // MARK: - Private Properties
    
    private let bookmarkKey = "NovoterraFOWSyncFolderBookmark"
    
    // MARK: - Bookmark Management
    
    /// Restore previously saved bookmark on app launch. Safe to call more than once.
    func restoreBookmark() -> URL? {
        if let syncFolderURL, isAccessGranted { return syncFolderURL }
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
                error = FileAccessError.securityScopeDenied
                return nil
            }
            
            syncFolderURL = url
            isAccessGranted = true
            return url
            
        } catch {
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
    func handleFolderSelection(_ url: URL) {
        // Start security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            error = FileAccessError.securityScopeDenied
            return
        }
        
        do {
            // Save bookmark for future launches
            try saveBookmark(for: url)

            // Release the previous folder, if any, before switching.
            if let previous = syncFolderURL, previous != url {
                previous.stopAccessingSecurityScopedResource()
            }
            syncFolderURL = url
            isAccessGranted = true
            error = nil
        } catch {
            self.error = error
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    // MARK: - Cleanup
    
    /// Stop accessing security-scoped resources
    func cleanup() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        if let url = syncFolderURL {
            url.stopAccessingSecurityScopedResource()
        }
        syncFolderURL = nil
        isAccessGranted = false
    }
}

// MARK: - Errors

enum FileAccessError: Error, LocalizedError {
    case securityScopeDenied
    
    var errorDescription: String? {
        switch self {
        case .securityScopeDenied:
            return "Access denied. Please grant permission to the Fog of World sync folder."
        }
    }
}
