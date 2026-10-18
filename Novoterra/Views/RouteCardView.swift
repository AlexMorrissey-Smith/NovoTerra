import SwiftUI
import MapKit

struct RouteCardView: View {
    let routeOption: RouteOption
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D
    
    @AppStorage("preferredNavigationApp") private var preferredNavApp: NavigationAppPreference = .showBoth
    @State private var showingAppPicker = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with level badge
            HStack {
                // Avoidance level badge
                Text(routeOption.avoidanceLevel.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badgeColor)
                    .foregroundStyle(.white)
                    .cornerRadius(6)
                
                Spacer()
                
                // New territory percentage
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("\(routeOption.newTerritoryPercentage)% New")
                        .bold()
                }
                .foregroundStyle(.green)
            }
            
            // Route stats
            HStack(spacing: 16) {
                // Distance
                VStack(alignment: .leading) {
                    Text("Distance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatDistance(routeOption.totalDistanceMeters))
                        .font(.subheadline.bold())
                }
                
                // New distance
                VStack(alignment: .leading) {
                    Text("New Territory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatDistance(routeOption.newDistanceMeters))
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                }
                
                Spacer()
            }
            
            // Navigation button(s) based on preference
            navigationButtons
        }
        .padding()
        .background(.background)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
    }
    
    @ViewBuilder
    private var navigationButtons: some View {
        switch preferredNavApp {
        case .showBoth:
            // Show picker with both options
            Button(action: { showingAppPicker = true }) {
                Label("Start Navigation", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .confirmationDialog("Choose Navigation App", isPresented: $showingAppPicker) {
                Button("Apple Maps") {
                    openNavigation(in: .appleMaps)
                }
                Button("Google Maps") {
                    openNavigation(in: .googleMaps)
                }
            }
            
        case .appleMaps:
            Button(action: { openNavigation(in: .appleMaps) }) {
                Label("Open in Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            
        case .googleMaps:
            Button(action: { openNavigation(in: .googleMaps) }) {
                Label("Open in Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private func openNavigation(in app: NavigationApp) {
        NavigationHandoff.openRoute(
            in: app,
            waypoints: routeOption.keyWaypoints,
            waypointNames: routeOption.waypointNames,
            origin: origin,
            destination: destination
        )
    }
    
    private var badgeColor: Color {
        switch routeOption.avoidanceLevel {
        case .exploration: return .purple
        case .adventurous: return .blue
        case .balanced: return .green
        }
    }
    
    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        } else {
            return String(format: "%.0f m", meters)
        }
    }
}

#Preview {
    RouteCardView(
        routeOption: RouteOption(
            id: UUID(),
            route: MKRoute(),
            avoidanceScore: 0.15,
            avoidanceLevel: .adventurous,
            totalDistanceMeters: 45000,
            expectedTravelTime: 1800,
            visitedDistanceMeters: 6750,
            keyWaypoints: []
        ),
        origin: CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
        destination: CLLocationCoordinate2D(latitude: -33.9, longitude: 151.3)
    )
    .padding()
}
