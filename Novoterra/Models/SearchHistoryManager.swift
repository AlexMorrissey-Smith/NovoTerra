import Foundation
import CoreLocation

struct RecentSearch: Codable, Identifiable, Hashable {
    var id: String { title + subtitle }
    let title: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    init(title: String, subtitle: String, coordinate: CLLocationCoordinate2D, timestamp: Date = Date()) {
        self.title = title
        self.subtitle = subtitle
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.timestamp = timestamp
    }
}

class SearchHistoryManager: ObservableObject {
    @Published var recentSearches: [RecentSearch] = []
    
    private let key = "recentSearches"
    private let maxHistory = 20
    
    init() {
        loadHistory()
    }
    
    func add(_ search: RecentSearch) {
        // Remove duplicates (same title/subtitle)
        recentSearches.removeAll { $0.id == search.id }
        
        // Add to front
        recentSearches.insert(search, at: 0)
        
        // Trim
        if recentSearches.count > maxHistory {
            recentSearches = Array(recentSearches.prefix(maxHistory))
        }
        
        saveHistory()
    }
    
    func clearHistory() {
        recentSearches.removeAll()
        saveHistory()
    }
    
    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(recentSearches) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RecentSearch].self, from: data) {
            recentSearches = decoded
        }
    }
}
