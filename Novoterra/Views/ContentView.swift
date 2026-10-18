import SwiftUI

struct ContentView: View {
    @EnvironmentObject var fowDataManager: FOWDataManager
    @EnvironmentObject var iCloudManager: iCloudFileManager
    
    var body: some View {
        TabView {
            RoutePlannerView()
                .tabItem {
                    Label("Plan Route", systemImage: "map")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .task {
            // Restore bookmark and load data on launch
            if let url = iCloudManager.restoreBookmark() {
                await fowDataManager.loadData(from: url)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(FOWDataManager())
        .environmentObject(iCloudFileManager())
}
