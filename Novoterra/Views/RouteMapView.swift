import SwiftUI
import MapKit

// MARK: - Route Map View

/// Simple MKMapView wrapper for displaying routes and markers (no fog overlay)
struct RouteMapView: UIViewRepresentable {
    @Binding var cameraPosition: MapCameraPosition
    var userLocation: CLLocationCoordinate2D?
    
    // Route to display
    var route: MKRoute?
    var secondLegRoute: MKRoute?
    var routeColor: UIColor = .systemBlue
    
    // Markers
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
        // Update coordinator parent reference to get latest state (e.g. routeColor)
        context.coordinator.parent = self
        
        // Update route overlays
        updateRouteOverlays(mapView)
        
        // Update annotations
        updateAnnotations(mapView)
        
        // Update camera position
        updateCamera(mapView, context: context)
    }
    
    private func updateRouteOverlays(_ mapView: MKMapView) {
        // Remove existing route overlays
        let existingRouteOverlays = mapView.overlays.filter { $0 is MKPolyline }
        mapView.removeOverlays(existingRouteOverlays)
        
        // Merge route polylines into one continuous line (fixes gaps in composite routes)
        guard let route = route else { return }
        
        var allCoordinates = extractPolylineCoordinates(route.polyline)
        
        if let secondLeg = secondLegRoute {
            let leg2Coords = extractPolylineCoordinates(secondLeg.polyline)
            // Append second leg coordinates (seamlessly connects at waypoint)
            allCoordinates.append(contentsOf: leg2Coords)
        }
        
        // Create single merged polyline
        let mergedPolyline = MKPolyline(coordinates: allCoordinates, count: allCoordinates.count)
        mapView.addOverlay(mergedPolyline, level: .aboveRoads)
    }
    
    private func extractPolylineCoordinates(_ polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let pointCount = polyline.pointCount
        guard pointCount > 0 else { return [] }
        
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
    
    private func updateAnnotations(_ mapView: MKMapView) {
        // Remove existing annotations (except user location)
        let existingAnnotations = mapView.annotations.filter { !($0 is MKUserLocation) }
        mapView.removeAnnotations(existingAnnotations)
        
        // Add origin marker
        if let origin = originMarker {
            let annotation = MKPointAnnotation()
            annotation.coordinate = origin.coordinate
            annotation.title = origin.title
            mapView.addAnnotation(annotation)
        }
        
        // Add destination marker
        if let dest = destinationMarker {
            let annotation = MKPointAnnotation()
            annotation.coordinate = dest.coordinate
            annotation.title = dest.title
            mapView.addAnnotation(annotation)
        }
    }
    
    private func updateCamera(_ mapView: MKMapView, context: Context) {
        // Only update if not being dragged by user
        guard !context.coordinator.isUserInteracting else { return }
        
        // MapCameraPosition handling
        if let rect = cameraPosition.rect {
            mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 100, left: 50, bottom: 250, right: 50), animated: true)
        } else if let region = cameraPosition.region {
            mapView.setRegion(region, animated: true)
        } else {
            // Default/User Location
            if mapView.userTrackingMode != .follow {
                mapView.setUserTrackingMode(.follow, animated: true)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        var isUserInteracting = false
        
        init(_ parent: RouteMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard let view = mapView.subviews.first,
                  let gestureRecognizers = view.gestureRecognizers else { return }
            
            // Check if any gesture execution caused this change
            for gesture in gestureRecognizers {
                if gesture.state == .began || gesture.state == .changed {
                    isUserInteracting = true
                    break
                }
            }
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isUserInteracting = false
            }
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = parent.routeColor
                renderer.lineWidth = 6
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            
            let identifier = "Marker"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            } else {
                view?.annotation = annotation
            }
            
            if annotation.title == parent.destinationMarker?.title {
                view?.markerTintColor = .systemGreen
            } else {
                view?.markerTintColor = .systemBlue
            }
            
            return view
        }
    }
}
