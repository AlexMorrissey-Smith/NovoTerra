import SwiftUI

@main
struct NovoterraApp: App {
    @StateObject private var fowDataManager = FOWDataManager()
    @StateObject private var iCloudManager = iCloudFileManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(fowDataManager)
                .environmentObject(iCloudManager)
                .task {
                    // Restore folder access and build the index once at launch.
                    if let folderURL = iCloudManager.restoreBookmark() {
                        await fowDataManager.loadData(from: folderURL)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await fowDataManager.clearCache() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up new Fog of World tracks when returning to the app.
            guard phase == .active, fowDataManager.isReady, let folderURL = iCloudManager.syncFolderURL else { return }
            Task { await fowDataManager.refreshIfStale(from: folderURL) }
        }
    }
}
