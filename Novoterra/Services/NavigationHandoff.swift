import Foundation
import MapKit
import UIKit

/// Hands a planned route off to an external navigation app.
@MainActor
enum NavigationHandoff {

    /// Opens the selected navigation app with the route's waypoints as intermediate stops.
    /// - Parameter origin: nil means "start from the user's current location".
    static func open(
        _ option: RouteOption,
        in app: NavigationApp,
        origin: CLLocationCoordinate2D?,
        destination: CLLocationCoordinate2D,
        destinationName: String,
        mode: TravelMode,
        avoiding avoidance: RouteAvoidance = .none
    ) {
        let waypoints = option.handoffWaypoints(maxCount: app.maxWaypoints, spacingMeters: mode.waypointSpacingMeters)

        switch app {
        case .appleMaps:
            openAppleMaps(origin: origin, waypoints: waypoints, destination: destination, destinationName: destinationName, mode: mode)
        case .googleMaps:
            openGoogleMaps(origin: origin, waypoints: waypoints, destination: destination, mode: mode, avoidance: avoidance)
        }
    }

    // MARK: - Apple Maps

    private static func openAppleMaps(
        origin: CLLocationCoordinate2D?,
        waypoints: [CLLocationCoordinate2D],
        destination: CLLocationCoordinate2D,
        destinationName: String,
        mode: TravelMode
    ) {
        // Apple Maps has no launch option to avoid tolls or highways. The via stops keep it on
        // the planned roads; between stops it follows the user's own Maps settings.
        // The first item is the start, the last is the destination, and anything between is a stop.
        let start: MKMapItem = origin.map { MKMapItem(placemark: MKPlacemark(coordinate: $0)) } ?? .forCurrentLocation()
        if origin != nil { start.name = "Start" }

        let stops = waypoints.enumerated().map { index, coord in
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
            item.name = "Via \(index + 1)"
            return item
        }

        let end = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        end.name = destinationName

        MKMapItem.openMaps(
            with: [start] + stops + [end],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.appleMapsMode]
        )
    }

    // MARK: - Google Maps (Universal Link)

    private static func openGoogleMaps(
        origin: CLLocationCoordinate2D?,
        waypoints: [CLLocationCoordinate2D],
        destination: CLLocationCoordinate2D,
        mode: TravelMode,
        avoidance: RouteAvoidance
    ) {
        // Docs: https://developers.google.com/maps/documentation/urls/get-started
        var components = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: format(destination)),
            URLQueryItem(name: "travelmode", value: mode.googleMapsMode),
        ]
        // Omitting origin makes Google Maps start from the current location.
        if let origin {
            items.append(URLQueryItem(name: "origin", value: format(origin)))
        }
        if mode == .driving, let avoid = avoidance.googleMapsValue {
            items.append(URLQueryItem(name: "avoid", value: avoid))
        }
        if !waypoints.isEmpty {
            items.append(URLQueryItem(name: "waypoints", value: waypoints.map(format).joined(separator: "|")))
        }
        components.queryItems = items

        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    private static func format(_ coord: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f", coord.latitude, coord.longitude)
    }
}
