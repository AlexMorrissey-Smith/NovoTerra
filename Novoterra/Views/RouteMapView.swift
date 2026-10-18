import SwiftUI
import MapKit

// MARK: - Route Map View

/// MKMapView wrapper showing the fog overlay, the selected route, and its alternatives.
struct RouteMapView: UIViewRepresentable {
    var cameraPosition: MapCameraPosition
    /// Bump to re-apply `cameraPosition`, even if it is unchanged (for example "show my location" after panning).
    var cameraRequestID: Int

    /// Selected route, drawn on top in `routeColor`.
    var selectedRoute: RouteOption?
    /// Other routes for the current level, drawn underneath in grey.
    var alternativeRoutes: [RouteOption] = []
    var routeColor: UIColor = .systemBlue

    /// Fog overlay source. nil hides the fog.
    var fogIndex: FOWSpatialIndex?
    /// Changes whenever the fog data changes, so tiles are re-rendered.
    var fogVersion: Int = 0

    var originMarker: (coordinate: CLLocationCoordinate2D, title: String)?
    var destinationMarker: (coordinate: CLLocationCoordinate2D, title: String)?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        updateFog(mapView, coordinator)
        updateRoutes(mapView, coordinator)
        updateAnnotations(mapView, coordinator)
        updateCamera(mapView, coordinator)
    }

    // MARK: - Overlays
    // SwiftUI calls updateUIView on every state change (including each location update),
    // so each section only touches the map when its own inputs changed.

    private func updateFog(_ mapView: MKMapView, _ coordinator: Coordinator) {
        let key = fogIndex == nil ? nil : fogVersion
        guard key != coordinator.fogKey else { return }
        coordinator.fogKey = key

        if let existing = coordinator.fogOverlay {
            mapView.removeOverlay(existing)
            coordinator.fogOverlay = nil
        }
        if let fogIndex {
            let overlay = FogTileOverlay(index: fogIndex)
            mapView.addOverlay(overlay, level: .aboveRoads)
            coordinator.fogOverlay = overlay
        }
    }

    private func updateRoutes(_ mapView: MKMapView, _ coordinator: Coordinator) {
        let key = [selectedRoute?.id] + alternativeRoutes.map { Optional($0.id) }
        let colorChanged = coordinator.routeColor != routeColor
        guard key != coordinator.routeKey || colorChanged else { return }
        coordinator.routeKey = key
        coordinator.routeColor = routeColor

        mapView.removeOverlays(mapView.overlays.filter { $0 is MKPolyline })

        for option in alternativeRoutes where option.id != selectedRoute?.id {
            let line = AlternativePolyline(coordinates: option.coordinates, count: option.coordinates.count)
            mapView.addOverlay(line, level: .aboveLabels)
        }
        if let selectedRoute {
            let line = MKPolyline(coordinates: selectedRoute.coordinates, count: selectedRoute.coordinates.count)
            mapView.addOverlay(line, level: .aboveLabels)
        }
    }

    private func updateAnnotations(_ mapView: MKMapView, _ coordinator: Coordinator) {
        let key = [originMarker.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" },
                   destinationMarker.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }]
        guard key != coordinator.annotationKey else { return }
        coordinator.annotationKey = key

        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })

        if let origin = originMarker {
            let annotation = EndpointAnnotation(isDestination: false)
            annotation.coordinate = origin.coordinate
            annotation.title = origin.title
            mapView.addAnnotation(annotation)
        }
        if let dest = destinationMarker {
            let annotation = EndpointAnnotation(isDestination: true)
            annotation.coordinate = dest.coordinate
            annotation.title = dest.title
            mapView.addAnnotation(annotation)
        }
    }

    private func updateCamera(_ mapView: MKMapView, _ coordinator: Coordinator) {
        guard cameraRequestID != coordinator.appliedCameraRequest else { return }
        coordinator.appliedCameraRequest = cameraRequestID

        if let rect = cameraPosition.rect {
            mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 180, left: 40, bottom: 320, right: 40), animated: true)
        } else if let region = cameraPosition.region {
            mapView.setRegion(region, animated: true)
        } else {
            mapView.setUserTrackingMode(.follow, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        var fogOverlay: FogTileOverlay?
        var fogKey: Int?? = .some(nil)
        var routeKey: [UUID?] = []
        var routeColor: UIColor?
        var annotationKey: [String?] = [nil, "unset"]
        var appliedCameraRequest: Int?

        init(_ parent: RouteMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tiles)
            }
            if let line = overlay as? AlternativePolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor.systemGray.withAlphaComponent(0.8)
                renderer.lineWidth = 4
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = parent.routeColor
                renderer.lineWidth = 6
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let endpoint = annotation as? EndpointAnnotation else { return nil }
            let identifier = "Endpoint"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = endpoint.isDestination ? .systemGreen : .systemBlue
            return view
        }
    }
}

/// Polyline subclass so the renderer can tell alternatives from the selected route.
private final class AlternativePolyline: MKPolyline {}

private final class EndpointAnnotation: MKPointAnnotation {
    let isDestination: Bool
    init(isDestination: Bool) {
        self.isDestination = isDestination
        super.init()
    }
}
