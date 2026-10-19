import Foundation
import MapKit
import Combine

/// Provides location search with autocomplete like Apple Maps
@MainActor
class LocationSearchService: NSObject, ObservableObject {
    
    @Published var searchResults: [MKLocalSearchCompletion] = []
    
    private let completer: MKLocalSearchCompleter
    
    override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }
    
    func search(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        completer.queryFragment = query
    }
    
    func getCoordinate(for completion: MKLocalSearchCompletion) async throws -> CLLocationCoordinate2D {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw SearchError.noResults
        }
        return item.placemark.coordinate
    }
}

extension LocationSearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.searchResults = results
        }
    }
    
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Partial queries often fail; the next keystroke retries, so keep the last results.
    }
}

enum SearchError: Error {
    case noResults
}

/// Represents origin or destination
struct RouteEndpoint: Equatable {
    let name: String
    let coordinate: CLLocationCoordinate2D?
    let isCurrentLocation: Bool
    
    static let currentLocation = RouteEndpoint(name: "Current Location", coordinate: nil, isCurrentLocation: true)
    
    static func == (lhs: RouteEndpoint, rhs: RouteEndpoint) -> Bool {
        lhs.name == rhs.name && lhs.isCurrentLocation == rhs.isCurrentLocation
    }
}
