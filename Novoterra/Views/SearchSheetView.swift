import SwiftUI
import MapKit
import CoreLocation

// MARK: - Location Manager Service

class LocationManagerService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocationCoordinate2D?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    private let manager = CLLocationManager()

    /// True when the user has turned location off for this app, or it's restricted.
    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }
    
    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Route planning only needs street-level accuracy; finer updates waste battery
        // and re-render the whole planner screen on every fix.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last?.coordinate
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isDenied {
            location = nil
        } else {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Temporary failures (no fix yet) are retried by Core Location; denial arrives
        // through the authorization callback, so there's nothing more to do here.
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
    @State private var lookupError: String?
    
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
                    
                    if let lookupError {
                        Label(lookupError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }

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
        lookupError = nil
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
                lookupError = "Couldn't find the location for \(result.title). Try another result."
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
