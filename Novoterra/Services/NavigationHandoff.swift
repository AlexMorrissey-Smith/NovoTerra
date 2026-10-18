import Foundation
import MapKit
import UIKit

/// Handles navigation handoff to external apps
struct NavigationHandoff {
    
    /// Opens the selected navigation app with the route
    static func openRoute(
        in app: NavigationApp,
        waypoints: [CLLocationCoordinate2D],
        waypointNames: [String?],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) {
        // Limit waypoints to app's maximum
        let limitedWaypoints = Array(waypoints.prefix(app.maxWaypoints))
        let limitedNames = Array(waypointNames.prefix(app.maxWaypoints))
        
        switch app {
        case .appleMaps:
            openAppleMaps(waypoints: limitedWaypoints, waypointNames: limitedNames, destination: destination)
        case .googleMaps:
            openGoogleMaps(waypoints: limitedWaypoints, origin: origin, destination: destination)
        }
    }
    
    // MARK: - Apple Maps (Official API)
    
    private static func openAppleMaps(
        waypoints: [CLLocationCoordinate2D],
        waypointNames: [String?],
        destination: CLLocationCoordinate2D
    ) {
        // Convert coordinates to MKMapItems
        // NOTE: Reverse geocoding is ASYNC - names must be pre-fetched while user views RouteCard
        // If not ready, fall back to "Checkpoint X" (reliable and fast)
        var mapItems: [MKMapItem] = waypoints.enumerated().map { index, coord in
            let placemark = MKPlacemark(coordinate: coord)
            let item = MKMapItem(placemark: placemark)
            item.name = waypointNames[safe: index] ?? "Checkpoint \(index + 1)"
            return item
        }
        
        // Add final destination
        let destPlacemark = MKPlacemark(coordinate: destination)
        let destItem = MKMapItem(placemark: destPlacemark)
        destItem.name = "Destination"
        mapItems.append(destItem)
        
        // Launch options
        let launchOptions: [String: Any] = [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ]
        
        // Open Apple Maps with multi-stop route
        MKMapItem.openMaps(with: mapItems, launchOptions: launchOptions)
    }
    
    // MARK: - Google Maps (Universal Link)
    
    private static func openGoogleMaps(
        waypoints: [CLLocationCoordinate2D],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) {
        // Use URLComponents for clean, safe URL construction
        // Docs: https://developers.google.com/maps/documentation/urls/get-started
        var components = URLComponents(string: "https://www.google.com/maps/dir/")!
        
        let waypointString = waypoints
            .map { "\($0.latitude),\($0.longitude)" }
            .joined(separator: "|")
        
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: "\(origin.latitude),\(origin.longitude)"),
            URLQueryItem(name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
            URLQueryItem(name: "waypoints", value: waypointString),
            URLQueryItem(name: "travelmode", value: "driving")
        ]
        
        guard let url = components.url else { return }
        
        // Universal Link handles app-or-web decision automatically
        UIApplication.shared.open(url)
    }
}

// MARK: - Safe Array Access Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
