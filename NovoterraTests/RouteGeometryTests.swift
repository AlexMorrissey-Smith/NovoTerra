import XCTest
import CoreLocation
import MapKit


final class RouteGeometryTests: XCTestCase {

    private let london = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)

    /// A straight path east of London, built from vertices of very uneven spacing.
    private func unevenPath(lengthMeters: Double) -> [CLLocationCoordinate2D] {
        var path = [london]
        var travelled = 0.0
        var step = 5.0
        while travelled < lengthMeters {
            step = step == 5 ? 400 : 5  // alternate dense and sparse vertices
            travelled = min(lengthMeters, travelled + step)
            path.append(Geo.offset(london, bearingDegrees: 90, meters: travelled))
        }
        return path
    }

    func testResampleSpacesPointsEvenlyRegardlessOfVertexDensity() {
        let path = unevenPath(lengthMeters: 2000)
        let samples = Geo.resample(path, every: 20)

        XCTAssertEqual(samples.count, 101, accuracy: 1)
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertEqual(Geo.distance(a, b), 20, accuracy: 0.5)
        }
    }

    func testOverlapFractionDetectsSharedAndSeparateGeometry() {
        let a = Geo.resample(unevenPath(lengthMeters: 1000), every: 10)
        let parallelNear = a.map { Geo.offset($0, bearingDegrees: 0, meters: 10) }
        let parallelFar = a.map { Geo.offset($0, bearingDegrees: 0, meters: 500) }

        XCTAssertEqual(Geo.overlapFraction(a, parallelNear, radius: 25), 1, accuracy: 0.01)
        XCTAssertEqual(Geo.overlapFraction(a, parallelFar, radius: 25), 0, accuracy: 0.01)
    }

    func testHandoffWaypointsAreEvenlySpacedAndKeepTheDetourPoint() {
        let path = Geo.resample(unevenPath(lengthMeters: 20_000), every: 50)
        let joinIndex = path.count / 3
        let option = RouteOption(
            legs: [],
            totalDistanceMeters: 20_000,
            expectedTravelTime: 1200,
            visitedDistanceMeters: 0,
            coordinates: path,
            joinIndex: joinIndex
        )

        let waypoints = option.handoffWaypoints(maxCount: 9, spacingMeters: 4000)
        XCTAssertEqual(waypoints.count, 4)  // 20 km / 4 km = 5 sections, so 4 intermediate stops
        XCTAssertTrue(waypoints.contains { Geo.distance($0, path[joinIndex]) < 1 }, "Detour point must be a handoff stop")

        let capped = option.handoffWaypoints(maxCount: 2, spacingMeters: 500)
        XCTAssertEqual(capped.count, 2)
    }

    func testPixelCoordinateRoundTrip() {
        let (gx, gy) = MercatorProjection.lngLatToGlobalPixel(lng: london.longitude, lat: london.latitude)
        let back = MercatorProjection.globalPixelToCoordinate(x: gx, y: gy)
        XCTAssertLessThan(Geo.distance(london, back), MercatorProjection.metersPerPixel(atLatitude: london.latitude))
    }

    func testMetersPerPixelMatchesKnownScale() {
        XCTAssertEqual(MercatorProjection.metersPerPixel(atLatitude: 0), 9.55, accuracy: 0.05)
        XCTAssertEqual(MercatorProjection.metersPerPixel(atLatitude: 51.5), 5.95, accuracy: 0.05)
    }
}
