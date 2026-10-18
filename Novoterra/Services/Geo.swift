import Foundation
import CoreLocation
import MapKit

/// Small spherical-geometry helpers used by route planning.
enum Geo {
    static let earthRadiusMeters = 6_371_000.0

    /// Great-circle distance in meters.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        return 2 * earthRadiusMeters * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Initial bearing from a to b, in degrees.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        return atan2(y, x) * 180 / .pi
    }

    /// Point reached by travelling `meters` from `coord` on the given bearing.
    static func offset(_ coord: CLLocationCoordinate2D, bearingDegrees: Double, meters: Double) -> CLLocationCoordinate2D {
        let angular = meters / earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180
        let lat1 = coord.latitude * .pi / 180
        let lng1 = coord.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lng2 = lng1 + atan2(sin(bearing) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lng2 * 180 / .pi)
    }

    /// Linear interpolation between two nearby coordinates.
    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    /// All vertices of a polyline.
    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    /// Total length of a path in meters.
    static func length(of path: [CLLocationCoordinate2D]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Points spaced evenly every `step` meters along the path, starting at its first vertex.
    /// Sampling by distance (not by vertex) keeps dense city geometry from outweighing sparse motorway geometry.
    static func resample(_ path: [CLLocationCoordinate2D], every step: Double) -> [CLLocationCoordinate2D] {
        guard let first = path.first, step > 0 else { return path }
        var result = [first]
        var carried = 0.0  // distance travelled since the last emitted sample
        for (a, b) in zip(path, path.dropFirst()) {
            let segment = distance(a, b)
            guard segment > 0 else { continue }
            var position = step - carried
            while position <= segment {
                result.append(interpolate(a, b, position / segment))
                position += step
            }
            carried = segment - (position - step)
        }
        return result
    }

    /// Fraction of points in `a` lying within `radius` meters of some point in `b`.
    /// Both inputs should already be resampled at a spacing below `radius`.
    static func overlapFraction(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D], radius: Double) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let grid = SpatialHash(points: b, cellMeters: radius)
        let hits = a.reduce(0) { $0 + (grid.hasPoint(near: $1, within: radius) ? 1 : 0) }
        return Double(hits) / Double(a.count)
    }
}

/// Uniform grid over coordinates for fast "is anything within r meters" queries.
struct SpatialHash {
    private struct Cell: Hashable { let x: Int; let y: Int }
    private var cells: [Cell: [CLLocationCoordinate2D]] = [:]
    private let cellDegreesLat: Double
    private let cellDegreesLng: Double

    init(points: [CLLocationCoordinate2D], cellMeters: Double) {
        let refLat = points.first?.latitude ?? 0
        cellDegreesLat = cellMeters / 111_320
        cellDegreesLng = cellMeters / (111_320 * max(0.01, cos(refLat * .pi / 180)))
        for p in points {
            cells[cell(for: p), default: []].append(p)
        }
    }

    private func cell(for p: CLLocationCoordinate2D) -> Cell {
        Cell(x: Int(floor(p.longitude / cellDegreesLng)), y: Int(floor(p.latitude / cellDegreesLat)))
    }

    func hasPoint(near p: CLLocationCoordinate2D, within meters: Double) -> Bool {
        let c = cell(for: p)
        for dy in -1...1 {
            for dx in -1...1 {
                if let bucket = cells[Cell(x: c.x + dx, y: c.y + dy)],
                   bucket.contains(where: { Geo.distance($0, p) <= meters }) {
                    return true
                }
            }
        }
        return false
    }
}
