import SwiftUI

@main
struct NovoterraApp: App {
    @StateObject private var fowDataManager = FOWDataManager()
    @StateObject private var iCloudManager = iCloudFileManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(fowDataManager)
                .environmentObject(iCloudManager)
                .task {
                    await onAppLaunch()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task {
                        print("NovoterraApp: Memory warning received, clearing cache")
                        await fowDataManager.clearCache()
                    }
                }
        }
    }
    
    /// Handle app launch - restore bookmark, sync if stale, start periodic sync
    private func onAppLaunch() async {
        // Restore last sync date from persistent storage
        iCloudManager.lastSyncDate = await LocalFileCache.shared.lastSyncDate
        
        // Restore saved bookmark
        if let folderURL = iCloudManager.restoreBookmark() {
            print("NovoterraApp: Restored folder access")
            
            // Sync if stale and load data
            await iCloudManager.syncFilesIfNeeded()
            await fowDataManager.loadData(from: folderURL)
            
            // Start periodic sync timer
            iCloudManager.startPeriodicSync()
        }
    }
}
