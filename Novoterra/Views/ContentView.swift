import SwiftUI

struct ContentView: View {
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
    }
}

#Preview {
    ContentView()
        .environmentObject(FOWDataManager())
        .environmentObject(iCloudFileManager())
}
