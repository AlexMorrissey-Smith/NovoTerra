import Foundation
import MapKit
import CoreLocation

/// Route planner with two-pass algorithm to defeat highway bias
@MainActor
class RoutePlanner: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var routes: [AvoidanceLevel: [RouteOption]] = [:]
    @Published var isCalculating: Bool = false
    @Published var error: Error?
    
    // MARK: - Dependencies
    
    // MARK: - Dependencies
    
    private let geocoder = CLGeocoder()
    
    init() {}
    
    // MARK: - Route Calculation
    
    /// Calculate routes with two-pass algorithm
    func calculateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType = .automobile,
        fowDataManager: FOWDataManager
    ) async {
        isCalculating = true
        routes = [:]  // [AvoidanceLevel: [RouteOption]]
        error = nil
        
        do {
            // Pass 1: Standard alternate routes from Apple Maps
            let standardRoutes = try await requestRoutes(
                from: origin,
                to: destination,
                transportType: transportType
            )
            
            var scoredRoutes: [RouteOption] = []
            
            for route in standardRoutes {
                let scored = await scoreRoute(route, origin: origin, destination: destination, fowDataManager: fowDataManager)
                scoredRoutes.append(scored)
            }
            
            // Pass 2: Find unexplored waypoints and route through them
            // This is the key to getting exploration routes
            let unexploredWaypoints = await findUnexploredWaypoints(
                from: origin,
                to: destination,
                fowDataManager: fowDataManager,
                count: 5  // Try up to 5 different unexplored waypoints
            )
            
            for waypoint in unexploredWaypoints {
                // Add delay to avoid rate limiting
                try await Task.sleep(nanoseconds: 300_000_000)  // 0.3s
                
                do {
                    let explorationRoutes = try await requestRouteViaWaypoint(
                        from: origin,
                        via: waypoint,
                        to: destination,
                        transportType: transportType
                    )
                    
                    for route in explorationRoutes {
                        let scored = await scoreRoute(route, origin: origin, destination: destination, fowDataManager: fowDataManager)
                        scoredRoutes.append(scored)
                    }
                } catch {
                    print("Exploration waypoint routing failed: \(error)")
                }
            }
            
            // Calculate direct distance for efficiency checks
            let directDistanceMeters = PivotPointGenerator.distance(from: origin, to: destination) * 1000 // meters
            let directDistanceKm = directDistanceMeters / 1000.0

            // Also try pivot points (perpendicular to route) for more variety
            // Dynamic offset: roughly 40% of distance, capped at 20km, min 0.5km
            let dynamicOffset = min(20.0, max(0.5, directDistanceKm * 0.4))
            
            let pivots = PivotPointGenerator.generatePivotPoints(from: origin, to: destination, offsetKm: dynamicOffset)
            for pivot in pivots {
                // Check if pivot area is unexplored
                let pivotIsUnexplored = await !fowDataManager.isCoordinateVisited(pivot)
                
                if pivotIsUnexplored {
                    // EFFICIENCY CHECK FOR PIVOTS
                    let distToPivot = PivotPointGenerator.distance(from: origin, to: pivot)
                    let distFromPivot = PivotPointGenerator.distance(from: pivot, to: destination)
                    // Pivot detour shouldn't be more than 2.0x the direct distance (looser than waypoints because it's just one point)
                    if (distToPivot + distFromPivot) < (directDistanceKm * 2.0) {
                        try await Task.sleep(nanoseconds: 300_000_000)
                        
                        do {
                            let pivotRoutes = try await requestRouteViaWaypoint(
                                from: origin,
                                via: pivot,
                                to: destination,
                                transportType: transportType
                            )
                            
                            for route in pivotRoutes {
                                let scored = await scoreRoute(route, origin: origin, destination: destination, fowDataManager: fowDataManager)
                                scoredRoutes.append(scored)
                            }
                        } catch {
                            print("Pivot routing failed: \(error)")
                        }
                    }
                }
            }
            
            // Now select the best route for each mode
            
            // POST-ROUTING SANITY CHECK: Filter out absurdly long routes
            // Route distance should not exceed 3x the direct distance (allows for reasonable detours)
            let maxReasonableDistance = directDistanceMeters * 3.0
            scoredRoutes = scoredRoutes.filter { route in
                let isReasonable = route.totalDistanceMeters <= maxReasonableDistance
                if !isReasonable {
                    print("DEBUG: Rejected route with distance \(String(format: "%.1f", route.totalDistanceMeters/1000))km (max: \(String(format: "%.1f", maxReasonableDistance/1000))km)")
                }
                return isReasonable
            }
            
            // 1. Deduplicate by route similarity (routes with similar distance AND new distance are duplicates)
            var uniqueRoutes: [RouteOption] = []
            for route in scoredRoutes {
                let isDuplicate = uniqueRoutes.contains { existing in
                    // Consider routes duplicates if both total distance and new distance are within 5%
                    let distRatio = abs(existing.totalDistanceMeters - route.totalDistanceMeters) / max(existing.totalDistanceMeters, 1)
                    let newDistRatio = abs(existing.newDistanceMeters - route.newDistanceMeters) / max(existing.newDistanceMeters, 1)
                    return distRatio < 0.05 && newDistRatio < 0.05
                }
                if !isDuplicate {
                    uniqueRoutes.append(route)
                }
            }
            
            print("DEBUG: Before sorting - \(uniqueRoutes.count) unique routes")
            for (i, r) in uniqueRoutes.enumerated() {
                print("DEBUG: Route \(i): newDist=\(String(format: "%.1f", r.newDistanceMeters/1000))km")
            }
            
            // 2. Read user's sorting preference and sort globally
            let sortingPref = UserDefaults.standard.string(forKey: "routeSortingPreference") ?? "New Distance"
            print("DEBUG: Sorting preference = '\(sortingPref)'")
            
            if sortingPref == "New Distance" {
                // Sort by new distance descending (most new territory first)
                uniqueRoutes.sort { $0.newDistanceMeters > $1.newDistanceMeters }
            } else {
                // Sort by unexplored percentage descending (lowest avoidance score = most unexplored)
                uniqueRoutes.sort { $0.avoidanceScore < $1.avoidanceScore }
            }
            
            print("DEBUG: After sorting:")
            for (i, r) in uniqueRoutes.enumerated() {
                print("DEBUG: Route \(i): newDist=\(String(format: "%.1f", r.newDistanceMeters/1000))km")
            }
            
            // 3. Assign top 6 routes to modes (2 per mode, in sorted order)
            var selectedRoutes: [AvoidanceLevel: [RouteOption]] = [
                .exploration: [],
                .adventurous: [],
                .balanced: []
            ]
            
            // Take up to 6 routes, assign 2 to each mode in order
            let topRoutes = Array(uniqueRoutes.prefix(6))
            
            for (index, route) in topRoutes.enumerated() {
                var modifiedRoute = route
                switch index {
                case 0, 1:
                    modifiedRoute.avoidanceLevel = .exploration
                    selectedRoutes[.exploration]!.append(modifiedRoute)
                    print("DEBUG: Assigned route \(index) (newDist=\(String(format: "%.1f", route.newDistanceMeters/1000))km) to Exploration")
                case 2, 3:
                    modifiedRoute.avoidanceLevel = .adventurous
                    selectedRoutes[.adventurous]!.append(modifiedRoute)
                    print("DEBUG: Assigned route \(index) (newDist=\(String(format: "%.1f", route.newDistanceMeters/1000))km) to Adventurous")
                case 4, 5:
                    modifiedRoute.avoidanceLevel = .balanced
                    selectedRoutes[.balanced]!.append(modifiedRoute)
                    print("DEBUG: Assigned route \(index) (newDist=\(String(format: "%.1f", route.newDistanceMeters/1000))km) to Balanced")
                default:
                    break
                }
            }
            
            self.routes = selectedRoutes
            
            print("DEBUG FINAL: Routes assigned to dictionary")
            for level in AvoidanceLevel.allCases {
                if let levelRoutes = selectedRoutes[level] {
                    for (i, r) in levelRoutes.enumerated() {
                        print("DEBUG FINAL: \(level.rawValue)[\(i)] = \(String(format: "%.1f", r.newDistanceMeters/1000))km")
                    }
                }
            }
            
            // TEMPORARILY DISABLED - was this scrambling order?
            // Task {
            //     await prefetchWaypointNames()
            // }
            
        } catch {
            self.error = error
        }
        
        // NOTE: Do NOT clear tile cache here - it breaks subsequent route calculations
        // Memory is managed via LRU eviction during calculation and memory warning handler
        
        isCalculating = false
    }
    
    // MARK: - Private Helpers
    
    private func requestRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType
        request.requestsAlternateRoutes = true
        
        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        
        return response.routes
    }
    
    /// Find unexplored waypoints in the corridor between origin and destination
    private func findUnexploredWaypoints(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        fowDataManager: FOWDataManager,
        count: Int
    ) async -> [CLLocationCoordinate2D] {
        var unexploredPoints: [CLLocationCoordinate2D] = []
        
        // Sample points in a grid around the direct route
        // Calculate corridor dimensions (perpendicular to route)
        let bearing = PivotPointGenerator.bearingBetween(origin, destination)
        
        // Sample at various offsets perpendicular to the route
        // Calculate direct distance
        let directDist = PivotPointGenerator.distance(from: origin, to: destination)
        
        // Dynamic offsets based on distance
        // For short trips (e.g. 0.5km), use small offsets (e.g. 0.1km, 0.2km)
        // For long trips (e.g. 50km), use larger offsets (e.g., 5km, 10km, 15km)
        
        let dynamicOffsets: [Double]
        if directDist < 2.0 { // Less than 2km
             // Very granular for walking/short drives
             dynamicOffsets = [-0.5, -0.3, -0.15, 0.15, 0.3, 0.5].map { $0 * directDist } // Scale by distance
        } else {
             // Standard scaling, capped at 15km
             let scale = min(15.0, directDist * 0.3)
             dynamicOffsets = [-1.0, -0.6, -0.3, 0.3, 0.6, 1.0].map { $0 * scale }
        }
        
        let positions: [Double] = [0.25, 0.5, 0.75]  // positions along route (fraction)
        
        for position in positions {
            // Point along the direct line
            let pointAlongRoute = CLLocationCoordinate2D(
                latitude: origin.latitude + (destination.latitude - origin.latitude) * position,
                longitude: origin.longitude + (destination.longitude - origin.longitude) * position
            )
            
            for offset in dynamicOffsets {
                // Calculate point perpendicular to route
                let testPoint = PivotPointGenerator.coordinateOffset(
                    from: pointAlongRoute,
                    bearingDegrees: bearing + 90,
                    distanceKm: offset
                )
                
                // Check if this point is unexplored
                let isUnexplored = await !fowDataManager.isCoordinateVisited(testPoint)
                
                if isUnexplored {
                    // SPUR CHECK: Ensure this waypoint makes sense geometrically
                    // Calculate distances
                    let distToPoint = PivotPointGenerator.distance(from: origin, to: testPoint)
                    let distFromPoint = PivotPointGenerator.distance(from: testPoint, to: destination)
                    // Direct distance already calculated above
                    
                    // 1. Efficiency Check: Detour must not be excessive (< 1.5x)
                    // 2. Forward Progress: Waypoint generally shouldn't be further from dest than start
                    //    (unless origin is very close to dest, but usually we want forward movement)
                    
                    let isEfficient = (distToPoint + distFromPoint) < (directDist * 1.5)
                    let makesProgress = distFromPoint < directDist
                    
                    if isEfficient && makesProgress {
                        unexploredPoints.append(testPoint)
                        
                        // Return early if we have enough
                        if unexploredPoints.count >= count {
                            return unexploredPoints
                        }
                    }
                }
            }
        }
        
        return unexploredPoints
    }
    
    /// Request a route that passes through a specific waypoint
    /// Returns routes via waypoint by scoring combined leg1+leg2
    private func requestRouteViaWaypoint(
        from origin: CLLocationCoordinate2D,
        via waypoint: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async throws -> [MKRoute] {
        // First leg: origin to waypoint
        let request1 = MKDirections.Request()
        request1.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request1.destination = MKMapItem(placemark: MKPlacemark(coordinate: waypoint))
        request1.transportType = transportType
        
        // Second leg: waypoint to destination  
        let request2 = MKDirections.Request()
        request2.source = MKMapItem(placemark: MKPlacemark(coordinate: waypoint))
        request2.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request2.transportType = transportType
        
        let directions1 = MKDirections(request: request1)
        let directions2 = MKDirections(request: request2)
        
        // Request both legs in parallel
        async let response1 = directions1.calculate()
        async let response2 = directions2.calculate()
        
        let (leg1Response, leg2Response) = try await (response1, response2)
        
        guard let leg1 = leg1Response.routes.first,
              let leg2 = leg2Response.routes.first else {
            return []
        }
        
        // Store combined route info for scoring
        // We'll create a synthetic composite by merging polyline coordinates
        pendingCompositeRoutes[leg1] = leg2
        
        return [leg1]
    }
    
    /// Temporary storage for composite route second legs
    private var pendingCompositeRoutes: [MKRoute: MKRoute] = [:]
    
    private func scoreRoute(_ route: MKRoute, origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, fowDataManager: FOWDataManager) async -> RouteOption {
        // Sample points along the polyline
        var coordinates = samplePolyline(route.polyline, interval: 50)
        
        // Check if this is a composite route (has a second leg)
        var totalDistance = route.distance
        var totalDuration = route.expectedTravelTime
        
        if let leg2 = pendingCompositeRoutes[route] {
            // Add leg2 coordinates, distance AND duration
            let leg2Coords = samplePolyline(leg2.polyline, interval: 50)
            coordinates.append(contentsOf: leg2Coords)
            totalDistance += leg2.distance
            totalDuration += leg2.expectedTravelTime
        }
        
        // Calculate visited percentage
        let visitedPercentage = await fowDataManager.visitedPercentageAlongPath(coordinates)
        
        // Determine avoidance level based on visited percentage
        let level: AvoidanceLevel
        if visitedPercentage < AvoidanceLevel.exploration.threshold {
            level = .exploration
        } else if visitedPercentage < AvoidanceLevel.adventurous.threshold {
            level = .adventurous
        } else {
            level = .balanced
        }
        
        // Extract waypoints for navigation handoff
        // Dynamic count: ~1 waypoint per 3km, capped at 12 (Apple Maps safe max)
        let dynamicWaypointCount = min(12, max(3, Int(totalDistance / 3000)))
        
        var waypoints: [CLLocationCoordinate2D]
        
        if let leg2 = pendingCompositeRoutes[route] {
            // For composite routes: use the JOIN POINT (end of leg 1) as the key waypoint
            // Plus strategic turn-based waypoints from each leg for accuracy
            let joinPoint = extractEndPoint(from: route)
            let leg1Turns = extractTurnWaypoints(from: route, maxCount: 2)
            let leg2Turns = extractTurnWaypoints(from: leg2, maxCount: 2)
            waypoints = leg1Turns + [joinPoint] + leg2Turns
        } else {
            // For direct routes: use turn-based extraction for Apple Maps accuracy
            waypoints = extractTurnWaypoints(from: route, maxCount: dynamicWaypointCount)
        }
        
        // Get second leg for map rendering
        let secondLeg = pendingCompositeRoutes[route]
        
        return RouteOption(
            id: UUID(),
            route: route,
            secondLegRoute: secondLeg,
            avoidanceScore: visitedPercentage,
            avoidanceLevel: level,
            totalDistanceMeters: totalDistance,
            expectedTravelTime: totalDuration,  // Correct total time
            visitedDistanceMeters: totalDistance * visitedPercentage,
            keyWaypoints: waypoints
        )
    }
    
    private func samplePolyline(_ polyline: MKPolyline, interval: Double) -> [CLLocationCoordinate2D] {
        let pointCount = polyline.pointCount
        guard pointCount > 0 else { return [] }
        
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        
        // Sample at intervals (simplified - actual implementation should use distance)
        let sampleRate = max(1, pointCount / 100)
        return stride(from: 0, to: pointCount, by: sampleRate).map { coordinates[$0] }
    }
    
    private func extractWaypoints(from route: MKRoute, maxCount: Int) -> [CLLocationCoordinate2D] {
        let polyline = route.polyline
        let pointCount = polyline.pointCount
        
        guard pointCount > 2 else { return [] }
        
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        
        // Skip first (origin) and last (destination)
        let intermediate = Array(coordinates.dropFirst().dropLast())
        
        guard intermediate.count > maxCount else { return intermediate }
        
        // Evenly distribute
        var result: [CLLocationCoordinate2D] = []
        let step = Double(intermediate.count) / Double(maxCount)
        
        for i in 0..<maxCount {
            let index = Int(Double(i) * step)
            result.append(intermediate[index])
        }
        
        return result
    }
    
    /// Extract waypoints from turn-by-turn instructions for better Apple Maps handoff accuracy
    private func extractTurnWaypoints(from route: MKRoute, maxCount: Int) -> [CLLocationCoordinate2D] {
        let steps = route.steps
        guard steps.count > 2 else {
            // Fallback to polyline extraction if no meaningful steps
            return extractWaypoints(from: route, maxCount: maxCount)
        }
        
        // Filter to significant navigation maneuvers (skip "continue straight" etc.)
        let significantSteps = steps.dropFirst().dropLast().filter { step in
            let instructions = step.instructions.lowercased()
            return instructions.contains("turn") ||
                   instructions.contains("take") ||
                   instructions.contains("merge") ||
                   instructions.contains("exit") ||
                   instructions.contains("head") ||
                   instructions.contains("onto")
        }
        
        // If no significant steps found, fall back to polyline extraction
        guard !significantSteps.isEmpty else {
            return extractWaypoints(from: route, maxCount: maxCount)
        }
        
        // Extract coordinates from the start of each significant step's polyline
        let stepCoords: [CLLocationCoordinate2D] = significantSteps.prefix(maxCount).compactMap { step in
            let polyline = step.polyline
            guard polyline.pointCount > 0 else { return nil }
            var coord = CLLocationCoordinate2D()
            polyline.getCoordinates(&coord, range: NSRange(location: 0, length: 1))
            return coord
        }
        
        return stepCoords.isEmpty ? extractWaypoints(from: route, maxCount: maxCount) : stepCoords
    }
    
    /// Extract the end point of a route (for composite route join points)
    private func extractEndPoint(from route: MKRoute) -> CLLocationCoordinate2D {
        let polyline = route.polyline
        let pointCount = polyline.pointCount
        guard pointCount > 0 else {
            return CLLocationCoordinate2D()
        }
        
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates.last ?? CLLocationCoordinate2D()
    }
    
    private func prefetchWaypointNames() async {
        var currentRoutes = routes
        
        for (level, options) in currentRoutes {
            var updatedOptions: [RouteOption] = []
            
            for var option in options {
                var names: [String?] = []
                
                for coord in option.keyWaypoints.prefix(5) {
                    let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    do {
                        let placemarks = try await geocoder.reverseGeocodeLocation(location)
                        names.append(placemarks.first?.locality ?? placemarks.first?.name)
                    } catch {
                        names.append(nil)
                    }
                }
                
                option.waypointNames = names
                updatedOptions.append(option)
            }
            currentRoutes[level] = updatedOptions
        }
        
        self.routes = currentRoutes
    }
}

// MARK: - Pivot Point Generator

struct PivotPointGenerator {
    
    /// Generate pivot points perpendicular to direct route
    static func generatePivotPoints(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        offsetKm: Double = 20
    ) -> [CLLocationCoordinate2D] {
        let midpoint = midpointBetween(origin, destination)
        let bearing = bearingBetween(origin, destination)
        
        let leftPivot = coordinateOffset(from: midpoint, bearingDegrees: bearing + 90, distanceKm: offsetKm)
        let rightPivot = coordinateOffset(from: midpoint, bearingDegrees: bearing - 90, distanceKm: offsetKm)
        
        return [leftPivot, rightPivot]
    }
    
    private static func midpointBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = (a.latitude + b.latitude) / 2
        let lng = (a.longitude + b.longitude) / 2
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
    
    /// Calculate distance in km between two points
    static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6371.0 // Earth radius in km
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        
        let val = sin(dLat/2) * sin(dLat/2) + sin(dLon/2) * sin(dLon/2) * cos(lat1) * cos(lat2)
        let c = 2 * atan2(sqrt(val), sqrt(1-val))
        
        return R * c
    }
    
    static func bearingBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        
        let y = sin(dLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        
        return atan2(y, x) * 180 / .pi
    }
    
    static func coordinateOffset(
        from coord: CLLocationCoordinate2D,
        bearingDegrees: Double,
        distanceKm: Double
    ) -> CLLocationCoordinate2D {
        let R = 6371.0  // Earth radius in km
        let bearing = bearingDegrees * .pi / 180
        let lat1 = coord.latitude * .pi / 180
        let lng1 = coord.longitude * .pi / 180
        
        let lat2 = asin(sin(lat1) * cos(distanceKm / R) + cos(lat1) * sin(distanceKm / R) * cos(bearing))
        let lng2 = lng1 + atan2(
            sin(bearing) * sin(distanceKm / R) * cos(lat1),
            cos(distanceKm / R) - sin(lat1) * sin(lat2)
        )
        
        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lng2 * 180 / .pi
        )
    }
}
