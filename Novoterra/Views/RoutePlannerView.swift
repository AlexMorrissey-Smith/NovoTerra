import SwiftUI
import MapKit
import CoreLocation

struct RoutePlannerView: View {
    @EnvironmentObject var fowDataManager: FOWDataManager
    @EnvironmentObject var iCloudManager: iCloudFileManager
    
    @StateObject private var searchService = LocationSearchService()
    @StateObject private var locationManager = LocationManagerService()
    @StateObject private var routePlanner = RoutePlanner()
    
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showFolderPicker = false
    @State private var showSearchSheet = false
    @State private var searchField: SearchField = .destination
    @State private var searchText = ""
    
    @State private var origin: RouteEndpoint = .currentLocation
    @State private var destination: RouteEndpoint?
    
    // Fog overlay removed
    
    @State private var selectedAvoidanceLevel: AvoidanceLevel = .exploration
    @State private var selectedRouteIndices: [AvoidanceLevel: Int] = [
        .exploration: 0,
        .adventurous: 0,
        .balanced: 0
    ]
    
    @AppStorage("routeSortingPreference") private var routeSortingPref: RouteSortingPreference = .newDistance
    
    var currentRoute: RouteOption? {
        // Routes come pre-sorted from RoutePlanner based on user preference
        let routes = routePlanner.routes[selectedAvoidanceLevel] ?? []
        let index = selectedRouteIndices[selectedAvoidanceLevel] ?? 0
        if routes.indices.contains(index) {
            return routes[index]
        }
        return routes.first
    }
    
    enum SearchField {
        case origin, destination
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-screen map
            mapView
            
            // Top bar overlay
            VStack(spacing: 0) {
                topBar
                Spacer()
            }
            
            // Bottom card (separate layer to extend behind tab bar)
            bottomCard
                .ignoresSafeArea(edges: .bottom)
        }
        .sheet(isPresented: $showFolderPicker) {
            folderPickerSheet
        }
        .sheet(isPresented: $showSearchSheet) {
            SearchSheetView(
                isPresented: $showSearchSheet,
                searchField: searchField,
                origin: $origin,
                destination: $destination,
                initialSearchText: searchText,
                onSelection: calculateIfReady
            )
        }
        .toolbarBackground(.hidden, for: .tabBar)

    }
    
    // MARK: - Map View
    
    private var mapView: some View {
        RouteMapView(
            cameraPosition: $position,
            userLocation: locationManager.location,
            route: currentRoute?.route as? MKRoute,
            secondLegRoute: currentRoute?.secondLegRoute as? MKRoute,
            routeColor: UIColor(routeColor(for: selectedAvoidanceLevel)),
            originMarker: (!origin.isCurrentLocation && resolvedOrigin != nil) ? (coordinate: resolvedOrigin!, title: origin.name) : nil,
            destinationMarker: resolvedDestination != nil ? (coordinate: resolvedDestination!, title: destination?.name ?? "Destination") : nil
        )
        .ignoresSafeArea()
    }
    
    private var resolvedOrigin: CLLocationCoordinate2D? {
        if origin.isCurrentLocation {
            return locationManager.location
        }
        return origin.coordinate
    }
    
    private var resolvedDestination: CLLocationCoordinate2D? {
        guard let dest = destination else { return nil }
        if dest.isCurrentLocation {
            return locationManager.location
        }
        return dest.coordinate
    }
    
    // MARK: - Top Bar
    
    private var topBar: some View {
        VStack(spacing: 8) {
            // Status banner
            if !iCloudManager.isAccessGranted {
                connectFOWBanner
            } else if fowDataManager.isLoading {
                loadingBanner
            }
            
            // Search card (Apple Maps style)
            searchCard
            
            HStack {
                Spacer()
                locationButton
            }
        }
        .padding(.top, 60)
        .padding(.horizontal)
    }
    
    private var connectFOWBanner: some View {
        Button { showFolderPicker = true } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Connect Fog of World Data")
                    .font(.caption.bold())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .padding(10)
            .background(.regularMaterial)
            .cornerRadius(10)
        }
    }
    
    private var loadingBanner: some View {
        HStack {
            ProgressView().scaleEffect(0.8)
            Text("Loading \(fowDataManager.tileCount) tiles...")
                .font(.caption)
            Spacer()
        }
        .padding(10)
        .background(.regularMaterial)
        .cornerRadius(10)
    }
    
    private var searchCard: some View {
        VStack(spacing: 0) {
            // Origin field
            HStack {
                Button {
                    searchField = .origin
                    searchText = origin.isCurrentLocation ? "" : origin.name
                    showSearchSheet = true
                } label: {
                    HStack {
                        Circle()
                            .fill(.blue)
                            .frame(width: 10, height: 10)
                        
                        Text(origin.name)
                            .foregroundStyle(origin.isCurrentLocation ? .blue : .primary)
                        
                        Spacer()
                    }
                }
                
                // Swap button
                Button {
                    swapEndpoints()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.blue)
                        .font(.caption)
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            
            Divider().padding(.leading, 34)
            
            // Destination field
            Button {
                searchField = .destination
                searchText = destination?.name ?? ""
                showSearchSheet = true
            } label: {
                HStack {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                    
                    Text(destination?.name ?? "Where to?")
                        .foregroundStyle(destination == nil ? .secondary : .primary)
                    
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(.regularMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
    
    private var locationButton: some View {
        Button {
            position = .userLocation(fallback: .automatic)
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 20))
                .foregroundStyle(.blue)
                .padding(8)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
    }
    
    private func swapEndpoints() {
        let oldOrigin = origin
        let oldDestination = destination
        
        // Swap: destination becomes origin, origin becomes destination
        if let dest = oldDestination {
            origin = dest
        } else {
            // No destination set, can't swap
            return
        }
        
        // Old origin becomes new destination
        destination = oldOrigin
        
        calculateIfReady()
    }
    
    // MARK: - Bottom Card
    
    @ViewBuilder
    private var bottomCard: some View {
        if destination != nil {
            if routePlanner.isCalculating {
                calculatingCard
            } else if !routePlanner.routes.isEmpty {
                routeResultsCard
            }
        }
    }
    
    private var calculatingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Finding routes...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .padding(.bottom, 16)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 20)
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
    }
    
    private var routeResultsCard: some View {
        VStack(spacing: 12) {
            // Exploration Mode Selector
            Picker("Exploration", selection: $selectedAvoidanceLevel) {
                ForEach(AvoidanceLevel.allCases) { level in
                    Text(level.rawValue).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 12)
            .onChange(of: selectedAvoidanceLevel) { _, _ in
                // Zoom to fit the newly selected route
                zoomToFitCurrentRoute()
            }
            
            if let routes = routePlanner.routes[selectedAvoidanceLevel], !routes.isEmpty {
                // Routes come pre-sorted from RoutePlanner
                // Route Selection Cards (if multiple)
                if routes.count > 1 {
                    HStack(spacing: 12) {
                        ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                            RouteOptionCard(
                                route: route,
                                index: index,
                                isSelected: index == (selectedRouteIndices[selectedAvoidanceLevel] ?? 0)
                            )
                            .onTapGesture {
                                selectedRouteIndices[selectedAvoidanceLevel] = index
                                zoomToFitCurrentRoute()
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                
                // Selected route details
                if let route = currentRoute {
                    selectedRouteDetails(option: route)
                }
            } else {
                ContentUnavailableView("No route found", systemImage: "location.slash")
                    .frame(height: 150)
            }
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(
            // Use UnevenRoundedRectangle to only round top corners, no clipping needed
            UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 20)
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
    }
    

    
    private func percentageColor(_ percentage: Int) -> Color {
        if percentage > 80 { return .green }
        if percentage > 50 { return .orange }
        return .red
    }
    
    @AppStorage("preferredNavigationApp") private var preferredNavApp: NavigationAppPreference = .showBoth
    
    private func selectedRouteDetails(option: RouteOption) -> some View {
        VStack(spacing: 16) {
            // Stats are now displayed in the cards above, removed from here to separate concerns and reduce clutter
            
            // Navigation button(s) based on preference
            switch preferredNavApp {
            case .showBoth:
                HStack(spacing: 12) {
                    Button { openInAppleMaps(option: option) } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                            Text("Apple Maps")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button { openInGoogleMaps(option: option) } label: {
                        HStack {
                            Image(systemName: "map")
                            Text("Google")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                
            case .appleMaps:
                Button { openInAppleMaps(option: option) } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        Text("Open in Maps")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                
            case .googleMaps:
                Button { openInGoogleMaps(option: option) } label: {
                    HStack {
                        Image(systemName: "map")
                        Text("Open in Maps")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Search Sheet
    
    // MARK: - Search Sheet
    
    // Moved to SearchSheetView.swift

    // MARK: - Folder Picker Sheet
    
    // MARK: - Folder Picker Sheet
    
    private var folderPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                
                Text("Connect Fog of World")
                    .font(.title2.bold())
                
                Text("Select your Fog of World folder in iCloud Drive.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                
                FolderPicker { url in
                    await iCloudManager.handleFolderSelection(url)
                    if iCloudManager.isAccessGranted, let folderURL = iCloudManager.syncFolderURL {
                        await fowDataManager.loadData(from: folderURL)
                    }
                    showFolderPicker = false
                }
            }
            .padding()
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Actions
    
    private func calculateIfReady() {
        guard let destCoord = resolvedDestination,
              let origCoord = resolvedOrigin else { return }
        
        Task {
            await routePlanner.calculateRoutes(
                from: origCoord,
                to: destCoord,
                fowDataManager: fowDataManager
            )
            
            // Adjust map position to fit routes
            // Must wait for calculation to finish and published property to update
            try? await Task.sleep(nanoseconds: 100_000_000) // Small delay to ensure state update
            await MainActor.run {
                zoomToFitCurrentRoute()
            }
        }
    }
    
    private func openInAppleMaps(option: RouteOption) {
        guard let dest = resolvedDestination, let orig = resolvedOrigin else { return }
        // Use pre-calculated waypoints from route option (includes both legs for composite routes)
        // Ensure we don't exceed the safe limit (though RoutePlanner should have already handled this approx)
        let safeWaypoints = Array(option.keyWaypoints.prefix(12))
        NavigationHandoff.openRoute(in: .appleMaps, waypoints: safeWaypoints, waypointNames: [], origin: orig, destination: dest)
    }
    
    private func openInGoogleMaps(option: RouteOption) {
        guard let dest = resolvedDestination, let orig = resolvedOrigin else { return }
        // Use pre-calculated waypoints
        let safeWaypoints = Array(option.keyWaypoints.prefix(10))
        NavigationHandoff.openRoute(in: .googleMaps, waypoints: safeWaypoints, waypointNames: [], origin: orig, destination: dest)
    }
    
    private func extractWaypoints(from route: MKRoute, maxCount: Int) -> [CLLocationCoordinate2D] {
        let polyline = route.polyline
        let pointCount = polyline.pointCount
        guard pointCount > 2 else { return [] }
        
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        
        let intermediate = Array(coordinates.dropFirst().dropLast())
        guard intermediate.count > maxCount else { return intermediate }
        
        var result: [CLLocationCoordinate2D] = []
        let step = Double(intermediate.count) / Double(maxCount)
        for i in 0..<maxCount {
            result.append(intermediate[Int(Double(i) * step)])
        }
        return result
    }
    
    // MARK: - Helpers
    
    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : String(format: "%.0f m", meters)
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
    
    private func routeColor(for level: AvoidanceLevel) -> Color {
        switch level {
        case .balanced: return .red
        case .adventurous: return .orange
        case .exploration: return .green
        }
    }
    
    private func zoomToFitCurrentRoute() {
        guard let routeOption = currentRoute else { return }
        
        var boundingMapRect: MKMapRect?
        
        if let mkRoute = routeOption.route as? MKRoute {
            boundingMapRect = mkRoute.polyline.boundingMapRect
        }
        
        if let secondLeg = routeOption.secondLegRoute as? MKRoute {
            if let rect = boundingMapRect {
                boundingMapRect = rect.union(secondLeg.polyline.boundingMapRect)
            } else {
                boundingMapRect = secondLeg.polyline.boundingMapRect
            }
        }
        
        if let rect = boundingMapRect {
            // Add significant padding to ensure start/end are visible
            // Top bar and bottom card take up a lot of space, so use 40% vertical padding
            let paddedRect = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.27)
            withAnimation {
                position = .rect(paddedRect)
            }
        }
    }

}

// MARK: - Location Manager Service

class LocationManagerService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocationCoordinate2D?
    private let manager = CLLocationManager()
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last?.coordinate
    }
}



struct SearchSheetView: View {
    @Binding var isPresented: Bool
    let searchField: RoutePlannerView.SearchField
    @Binding var origin: RouteEndpoint
    @Binding var destination: RouteEndpoint?
    let initialSearchText: String
    let onSelection: () -> Void
    
    @State private var searchText = ""
    @StateObject private var searchService = LocationSearchService()
    @StateObject private var historyManager = SearchHistoryManager()
    @FocusState private var isSearchFocused: Bool
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Search Bar Container
                    HStack(spacing: 12) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.secondary)
                            
                            TextField(searchField == .origin ? "Search..." : "Search for a place or address", text: $searchText)
                                .font(.system(size: 17))
                                .focused($isSearchFocused)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .onChange(of: searchText) { _, newValue in
                                    searchService.search(query: newValue)
                                }
                            
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.gray)
                                        .font(.system(size: 18))
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        
                        Button("Cancel") {
                            isPresented = false
                        }
                        .foregroundStyle(.blue)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 20) // Top padding for sheet handle
                    
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            
                            // 1. Current Location Option (Only if search text is empty)
                            if searchText.isEmpty {
                                let shouldShowCurrentLocation = searchField == .origin || !origin.isCurrentLocation
                                
                                if shouldShowCurrentLocation {
                                    Button {
                                        selectCurrentLocation()
                                    } label: {
                                        HStack(alignment: .center, spacing: 16) {
                                            Image(systemName: "location.fill")
                                                .font(.title3)
                                                .frame(width: 30, height: 30)
                                                .background(.blue)
                                                .foregroundStyle(.white)
                                                .clipShape(Circle())
                                            
                                            Text("Current Location")
                                                .font(.body)
                                                .foregroundStyle(.blue)
                                            
                                            Spacer()
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 12)
                                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                                        .cornerRadius(10)
                                    }
                                    .padding(.horizontal)
                                    .padding(.bottom, 20)
                                }
                                
                                // 2. Recents Section
                                if !historyManager.recentSearches.isEmpty {
                                    Section {
                                        VStack(spacing: 0) {
                                            ForEach(historyManager.recentSearches) { recent in
                                                Button {
                                                    selectRecentSearch(recent)
                                                } label: {
                                                    SearchRowView(title: recent.title, subtitle: recent.subtitle, iconName: "clock.fill", iconColor: .gray)
                                                }
                                                
                                                if recent.id != historyManager.recentSearches.last?.id {
                                                    Divider().padding(.leading, 56)
                                                }
                                            }
                                        }
                                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                                        .cornerRadius(10)
                                        .padding(.horizontal)
                                    } header: {
                                        HStack {
                                            Text("Recents")
                                                .font(.headline)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Button("Clear") {
                                                historyManager.clearHistory()
                                            }
                                            .font(.caption)
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 8)
                                    }
                                    .padding(.bottom, 20)
                                }
                            }
                            
                            // 3. Search Results
                            if !searchService.searchResults.isEmpty {
                                Section {
                                    VStack(spacing: 0) {
                                        ForEach(searchService.searchResults, id: \.self) { result in
                                            Button {
                                                selectSearchResult(result)
                                            } label: {
                                                SearchRowView(title: result.title, subtitle: result.subtitle, iconName: "mappin.circle.fill", iconColor: .red)
                                            }
                                            
                                            if result != searchService.searchResults.last {
                                                Divider().padding(.leading, 56)
                                            }
                                        }
                                    }
                                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    .cornerRadius(10)
                                    .padding(.horizontal)
                                } header: {
                                    if !searchText.isEmpty {
                                        HStack {
                                            Text("Results")
                                                .font(.headline)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 8)
                                    }
                                }
                            }
                        }
                        .padding(.top, 0)
                    }
                }
            }
            .navigationBarHidden(true) // Hide default nav bar to use custom search styling
            .onAppear {
                searchText = initialSearchText
                // Small delay not needed for focus but helps with animation smoothness sometimes
                isSearchFocused = true
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    
    private func selectCurrentLocation() {
        let endpoint = RouteEndpoint(name: "Current Location", coordinate: CLLocationCoordinate2D(), isCurrentLocation: true)
        updateSelection(endpoint: endpoint)
    }
    
    private func selectRecentSearch(_ recent: RecentSearch) {
        let endpoint = RouteEndpoint(name: recent.title, coordinate: recent.coordinate, isCurrentLocation: false)
        updateSelection(endpoint: endpoint)
    }
    
    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        Task {
            do {
                let coord = try await searchService.getCoordinate(for: result)
                
                // Add to history
                let recent = RecentSearch(title: result.title, subtitle: result.subtitle, coordinate: coord)
                await MainActor.run {
                    historyManager.add(recent)
                }
                
                let endpoint = RouteEndpoint(name: result.title, coordinate: coord, isCurrentLocation: false)
                updateSelection(endpoint: endpoint)
            } catch {
                print("Failed to get coordinate: \(error)")
            }
        }
    }
    
    private func updateSelection(endpoint: RouteEndpoint) {
        if searchField == .origin {
            origin = endpoint
        } else {
            destination = endpoint
        }
        isPresented = false
        onSelection()
    }
    

}

struct SearchRowView: View {
    let title: String
    let subtitle: String
    let iconName: String
    let iconColor: Color
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(iconColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .contentShape(Rectangle()) // Make full row tappable
    }

}

// MARK: - Corner Radius Extension

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }

}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

#Preview {
    RoutePlannerView()
        .environmentObject(FOWDataManager())
        .environmentObject(iCloudFileManager())
}
