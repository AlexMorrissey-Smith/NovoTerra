import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var iCloudManager: iCloudFileManager
    @EnvironmentObject var fowDataManager: FOWDataManager
    
    @State private var showFolderPicker = false
    @AppStorage("preferredNavigationApp") private var preferredNavApp: NavigationAppPreference = .showBoth
    @AppStorage("routeSortingPreference") private var routeSortingPreference: RouteSortingPreference = .newDistance
    @AppStorage("showFog") private var showFog = true
    
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
                        
                        HStack {
                            if fowDataManager.isLoading {
                                ProgressView().scaleEffect(0.8)
                                Text("Syncing…")
                            } else if let lastSync = fowDataManager.lastSyncDate {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Last synced \(lastSync, style: .relative) ago")
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Never synced")
                            }
                            Spacer()
                        }
                        .foregroundStyle(.secondary)

                        if fowDataManager.pendingDownloads > 0 {
                            Label("\(fowDataManager.pendingDownloads) tiles still downloading from iCloud", systemImage: "icloud.and.arrow.down")
                                .foregroundStyle(.secondary)
                        }

                        if let error = fowDataManager.error {
                            Label(error.localizedDescription, systemImage: "exclamationmark.octagon")
                                .foregroundStyle(.red)
                        }

                        Button {
                            guard let folderURL = iCloudManager.syncFolderURL else { return }
                            Task { await fowDataManager.loadData(from: folderURL) }
                        } label: {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(fowDataManager.isLoading)

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
                
                Section("Map") {
                    Toggle("Show Fog", isOn: $showFog)
                }

                Section {
                    Picker("Sort Routes By", selection: $routeSortingPreference) {
                        ForEach(RouteSortingPreference.allCases) { pref in
                            Text(pref.rawValue).tag(pref)
                        }
                    }
                } header: {
                    Text("Route Sorting")
                } footer: {
                    Text("Within each exploration level, routes are ranked by this. Levels differ in how much longer than the fastest route they allow: Balanced 20%, Adventurous 50%, Exploration 100%.")
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
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                iCloudManager.handleFolderSelection(url)
                guard iCloudManager.isAccessGranted, let folderURL = iCloudManager.syncFolderURL else { return }
                Task { await fowDataManager.loadData(from: folderURL) }
            }
        }
    }
    
    private func disconnectData() {
        iCloudManager.cleanup()
        Task {
            await fowDataManager.reset()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(iCloudFileManager())
        .environmentObject(FOWDataManager())
}
