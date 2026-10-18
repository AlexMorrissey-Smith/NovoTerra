import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var iCloudManager: iCloudFileManager
    @EnvironmentObject var fowDataManager: FOWDataManager
    
    @State private var showFolderPicker = false
    @AppStorage("preferredNavigationApp") private var preferredNavApp: NavigationAppPreference = .showBoth
    @AppStorage("routeSortingPreference") private var routeSortingPreference: RouteSortingPreference = .newDistance
    
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Data Source Section
                Section("Fog of World Data") {
                    if iCloudManager.isAccessGranted {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected")
                            Spacer()
                            Text("\(fowDataManager.tileCount) tiles")
                                .foregroundStyle(.secondary)
                        }
                        
                        // Sync status - always show last sync if available
                        HStack {
                            if iCloudManager.isSyncing {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Syncing...")
                                    .foregroundStyle(.secondary)
                            } else if let lastSync = iCloudManager.lastSyncDate {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.secondary)
                                Text("Last synced \(lastSync, style: .relative) ago")
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.secondary)
                                Text("Never synced")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        
                        Button {
                            Task {
                                await iCloudManager.syncNow()
                                if let folderURL = iCloudManager.syncFolderURL {
                                    await fowDataManager.loadData(from: folderURL)
                                }
                            }
                        } label: {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(iCloudManager.isSyncing)
                        
                        Button(role: .destructive) {
                            disconnectData()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                    } else {
                        Button {
                            showFolderPicker = true
                        } label: {
                            Label("Connect FOW Folder", systemImage: "folder.badge.plus")
                        }
                    }
                }
                
                // Preferences Section
                Section("Navigation Preferences") {
                    Picker("Preferred App", selection: $preferredNavApp) {
                        ForEach(NavigationAppPreference.allCases) { app in
                            Text(app.rawValue).tag(app)
                        }
                    }
                }
                
                Section("Route Sorting") {
                    Picker("Sort Routes By", selection: $routeSortingPreference) {
                        ForEach(RouteSortingPreference.allCases) { pref in
                            Text(pref.rawValue).tag(pref)
                        }
                    }
                }
                
                // About Section
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in
                    await iCloudManager.handleFolderSelection(url)
                    if iCloudManager.isAccessGranted, let folderURL = iCloudManager.syncFolderURL {
                        await fowDataManager.loadData(from: folderURL)
                        iCloudManager.startPeriodicSync()
                        iCloudManager.lastSyncDate = await LocalFileCache.shared.lastSyncDate
                    }
                }
            }
        }
    }
    
    private func disconnectData() {
        iCloudManager.cleanup()
        Task {
            await fowDataManager.clearCache()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(iCloudFileManager())
        .environmentObject(FOWDataManager())
}
