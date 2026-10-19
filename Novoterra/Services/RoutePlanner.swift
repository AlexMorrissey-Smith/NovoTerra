import Foundation
import MapKit
import CoreLocation
import os

/// Finds routes that cover the most unexplored ground.
///
/// MapKit can't be told to avoid areas, so the planner:
/// 1. asks for Apple's normal alternatives,
/// 2. picks candidate waypoints in the least-explored parts of the corridor and routes through them,
/// 3. scores every candidate by how much of its length is new territory,
/// 4. lets each exploration level choose from the routes within its time budget.
@MainActor
final class RoutePlanner: ObservableObject {

    private nonisolated static let log = Logger(subsystem: "com.novoterra.app", category: "RoutePlanner")

    // MARK: - Published State

    /// Every distinct candidate route, fastest first.
    @Published private(set) var options: [RouteOption] = []
    @Published private(set) var isCalculating = false
    @Published var error: Error?
    /// True when routes were scored before any fog data was available, so every route counts as new.
    @Published private(set) var scoredWithoutFogData = false

    private var currentTask: Task<Void, Never>?

    // MARK: - Tuning

    /// Distance between scoring samples along a route.
    private nonisolated static let sampleSpacingMeters = 20.0
    /// How close a past track must be for a road to count as visited.
    private nonisolated static let visitedToleranceMeters = 20.0
    /// Maximum number of detour waypoints to try (each costs two MapKit requests).
    private nonisolated static let maxDetourCandidates = 6
    /// MapKit throttles at roughly 50 requests per minute; keep bursts small.
    private nonisolated static let maxConcurrentDetours = 3

    // MARK: - Public Interface

    /// Routes for an exploration level: those within its time budget, best first, at most three.
    func routes(for level: AvoidanceLevel, sortedBy sorting: RouteSortingPreference) -> [RouteOption] {
        guard let fastest = options.first(where: \.isFastest) else { return [] }
        let budget = fastest.expectedTravelTime * level.maxTimeRatio
        let eligible = options.filter { $0.expectedTravelTime <= budget + 1 }
        let sorted = eligible.sorted { a, b in
            switch sorting {
            case .newDistance:
                if abs(a.newDistanceMeters - b.newDistanceMeters) > 50 { return a.newDistanceMeters > b.newDistanceMeters }
            case .unexploredPercentage:
                if abs(a.visitedFraction - b.visitedFraction) > 0.01 { return a.visitedFraction < b.visitedFraction }
            }
            return a.expectedTravelTime < b.expectedTravelTime
        }
        return Array(sorted.prefix(3))
    }

    /// Start planning, cancelling any calculation already running.
    func plan(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        mode: TravelMode,
        avoiding avoidance: RouteAvoidance = .none,
        index: FOWSpatialIndex
    ) {
        currentTask?.cancel()
        isCalculating = true
        error = nil
        options = []

        currentTask = Task {
            do {
                let hasFogData = await index.tileCount > 0
                let result = try await Self.computeOptions(from: origin, to: destination, mode: mode, avoidance: avoidance, index: index)
                try Task.checkCancellation()
                options = result
                scoredWithoutFogData = !hasFogData
                if result.isEmpty { error = PlannerError.noRoutes }
            } catch is CancellationError {
                return
            } catch {
                // MapKit reports cancelled requests as its own errors.
                if Task.isCancelled { return }
                Self.log.error("Planning failed: \(error.localizedDescription)")
                if let mapKitError = error as? MKError, mapKitError.code == .loadingThrottled {
                    self.error = PlannerError.throttled
                } else {
                    self.error = error
                }
            }
            isCalculating = false
        }
    }

    /// Score the current routes again against updated fog data, without new MapKit requests.
    /// Route IDs are kept so the user's selected route stays selected.
    func rescore(index: FOWSpatialIndex) {
        guard !options.isEmpty, !isCalculating else { return }
        let previous = options
        currentTask?.cancel()
        currentTask = Task {
            let hasFogData = await index.tileCount > 0
            var scored: [RouteOption] = []
            for old in previous {
                guard var option = await Self.score(legs: old.legs, index: index) else { continue }
                option.id = old.id
                scored.append(option)
            }
            guard !Task.isCancelled else { return }
            options = Self.rank(scored)
            scoredWithoutFogData = !hasFogData
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isCalculating = false
    }

    func clear() {
        cancel()
        options = []
        error = nil
    }

    // MARK: - Pipeline

    nonisolated private static func computeOptions(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        mode: TravelMode,
        avoidance: RouteAvoidance,
        index: FOWSpatialIndex
    ) async throws -> [RouteOption] {
        // Pass 1: Apple's own alternatives. These anchor the "fastest" baseline.
        let direct = try await requestRoutes(from: origin, to: destination, mode: mode, avoidance: avoidance, alternates: true)
        try Task.checkCancellation()
        guard let fastestDirect = direct.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
            throw PlannerError.noRoutes
        }

        var candidates: [[MKRoute]] = direct.map { [$0] }

        // Pass 2: force routes through the least-explored parts of the corridor.
        let waypoints = await detourWaypoints(from: origin, to: destination, roadDistance: fastestDirect.distance, index: index)
        try Task.checkCancellation()
        candidates += await routesVia(waypoints, from: origin, to: destination, mode: mode, avoidance: avoidance)
        try Task.checkCancellation()

        // Score every candidate by distance-weighted visited coverage.
        var scored: [RouteOption] = []
        for legs in candidates {
            try Task.checkCancellation()
            if let option = await score(legs: legs, index: index) {
                scored.append(option)
            }
        }

        return rank(scored)
    }

    /// Candidate waypoints, best first: unexplored, spread out, and not too far off the direct line.
    nonisolated private static func detourWaypoints(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        roadDistance: Double,
        index: FOWSpatialIndex
    ) async -> [CLLocationCoordinate2D] {
        let direct = Geo.distance(origin, destination)
        guard direct > 200 else { return [] }

        let bearing = Geo.bearing(origin, destination)
        let maxOffset = min(direct * 0.45, 20_000)
        let probeRadius = min(max(direct * 0.06, 150), 2_500)
        // Straight-line detour allowance; the road detour is checked again after routing.
        let maxDetour = max(direct * 1.6, roadDistance * 1.3)

        struct Candidate { let point: CLLocationCoordinate2D; let score: Double }
        var candidates: [Candidate] = []

        for position in stride(from: 0.2, through: 0.8, by: 0.15) {
            let onLine = Geo.interpolate(origin, destination, position)
            for fraction in [-1.0, -0.66, -0.33, 0.0, 0.33, 0.66, 1.0] {
                let point = Geo.offset(onLine, bearingDegrees: bearing + 90, meters: fraction * maxOffset)
                let detour = Geo.distance(origin, point) + Geo.distance(point, destination)
                guard detour <= maxDetour else { continue }

                let unexplored = await index.unexploredFraction(around: point, radiusMeters: probeRadius)
                guard unexplored >= 0.3 else { continue }

                // Prefer unexplored areas, with a mild penalty for long detours.
                let detourPenalty = (detour / direct - 1) * 0.5
                candidates.append(Candidate(point: point, score: unexplored - detourPenalty))
            }
        }

        // Greedy pick with a minimum spacing so the candidates explore different areas.
        let minSpacing = direct * 0.15
        var picked: [CLLocationCoordinate2D] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard picked.count < maxDetourCandidates else { break }
            if picked.allSatisfy({ Geo.distance($0, candidate.point) >= minSpacing }) {
                picked.append(candidate.point)
            }
        }
        return picked
    }

    /// Two-leg routes through each waypoint, requested a few at a time.
    nonisolated private static func routesVia(
        _ waypoints: [CLLocationCoordinate2D],
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        mode: TravelMode,
        avoidance: RouteAvoidance
    ) async -> [[MKRoute]] {
        var results: [[MKRoute]] = []
        var remaining = waypoints[...]

        while !remaining.isEmpty, !Task.isCancelled {
            let batch = remaining.prefix(maxConcurrentDetours)
            remaining = remaining.dropFirst(batch.count)

            var throttled = false
            await withTaskGroup(of: Result<[MKRoute], Error>.self) { group in
                for waypoint in batch {
                    group.addTask {
                        do {
                            async let leg1 = requestRoutes(from: origin, to: waypoint, mode: mode, avoidance: avoidance, alternates: false)
                            async let leg2 = requestRoutes(from: waypoint, to: destination, mode: mode, avoidance: avoidance, alternates: false)
                            let (first, second) = try await (leg1, leg2)
                            guard let a = first.first, let b = second.first else { return .success([]) }
                            return .success([a, b])
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let legs) where !legs.isEmpty:
                        results.append(legs)
                    case .failure(let error as MKError) where error.code == .loadingThrottled:
                        throttled = true
                    default:
                        break
                    }
                }
            }
            if throttled {
                log.notice("MapKit throttled detour requests; using routes found so far")
                break
            }
        }
        return results
    }

    /// Build a scored RouteOption, or nil if the route doubles back on itself.
    nonisolated private static func score(legs: [MKRoute], index: FOWSpatialIndex) async -> RouteOption? {
        var path: [CLLocationCoordinate2D] = []
        var joinIndex: Int?
        for (i, leg) in legs.enumerated() {
            let coords = Geo.coordinates(of: leg.polyline)
            if i > 0 {
                joinIndex = path.count - 1
                path.append(contentsOf: coords.dropFirst())
            } else {
                path.append(contentsOf: coords)
            }
        }
        guard path.count >= 2 else { return nil }

        let totalDistance = legs.reduce(0) { $0 + $1.distance }
        let totalTime = legs.reduce(0) { $0 + $1.expectedTravelTime }

        // Reject "there and back" spurs: a waypoint off a dead end makes the second leg retrace the first.
        if legs.count == 2 {
            let leg1 = Geo.resample(Geo.coordinates(of: legs[0].polyline), every: sampleSpacingMeters)
            let leg2 = Geo.resample(Geo.coordinates(of: legs[1].polyline), every: sampleSpacingMeters)
            let retraced = Geo.overlapFraction(leg2, leg1, radius: 25) * legs[1].distance
            if retraced > max(400, totalDistance * 0.1) { return nil }
        }

        let samples = Geo.resample(path, every: sampleSpacingMeters)
        let mask = await index.visitedMask(for: samples, toleranceMeters: visitedToleranceMeters)
        let visitedFraction = mask.isEmpty ? 0 : Double(mask.filter { $0 }.count) / Double(mask.count)

        return RouteOption(
            legs: legs,
            totalDistanceMeters: totalDistance,
            expectedTravelTime: totalTime,
            visitedDistanceMeters: totalDistance * visitedFraction,
            coordinates: path,
            joinIndex: joinIndex
        )
    }

    /// Drop duplicates and unreasonable detours, then annotate each route relative to the fastest.
    nonisolated private static func rank(_ scored: [RouteOption]) -> [RouteOption] {
        guard let fastest = scored.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else { return [] }

        let maxTime = fastest.expectedTravelTime * AvoidanceLevel.allCases.map(\.maxTimeRatio).max()!
        let reasonable = scored
            .filter { $0.expectedTravelTime <= maxTime + 1 }
            .sorted { $0.expectedTravelTime < $1.expectedTravelTime }

        // Two routes are the same if nearly all of each lies on the other. Keep the faster one.
        var unique: [(option: RouteOption, samples: [CLLocationCoordinate2D])] = []
        for option in reasonable {
            let samples = Geo.resample(option.coordinates, every: 50)
            let isDuplicate = unique.contains { existing in
                Geo.overlapFraction(samples, existing.samples, radius: 40) > 0.9 &&
                Geo.overlapFraction(existing.samples, samples, radius: 40) > 0.9
            }
            if !isDuplicate { unique.append((option, samples)) }
        }

        return unique.map { entry in
            var option = entry.option
            option.isFastest = option.id == fastest.id
            option.extraTimeVsFastest = option.expectedTravelTime - fastest.expectedTravelTime
            option.extraNewDistanceVsFastest = option.newDistanceMeters - fastest.newDistanceMeters
            return option
        }
    }

    nonisolated private static func requestRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        mode: TravelMode,
        avoidance: RouteAvoidance,
        alternates: Bool
    ) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = mode.transportType
        request.requestsAlternateRoutes = alternates
        if mode == .driving {
            request.tollPreference = avoidance.tolls ? .avoid : .any
            request.highwayPreference = avoidance.highways ? .avoid : .any
        }
        // Cancelling the Swift task doesn't stop an MKDirections request, which would
        // still count against MapKit's rate limit, so cancel it explicitly.
        let directions = MKDirections(request: request)
        return try await withTaskCancellationHandler {
            try await directions.calculate().routes
        } onCancel: {
            directions.cancel()
        }
    }
}

// MARK: - Errors

enum PlannerError: Error, LocalizedError {
    case noRoutes
    case throttled

    var errorDescription: String? {
        switch self {
        case .noRoutes: return "No routes found for this trip. Try another travel mode or destination."
        case .throttled: return "Apple Maps is limiting route requests. Wait a minute, then try again."
        }
    }
}
