import Foundation

enum LocationCoordinateSystem: String, CaseIterable, Identifiable {
    case wgs84, gcj02
    var id: String { rawValue }
    var title: String { self == .wgs84 ? "GPS 坐标（WGS-84）" : "大陆地图坐标（GCJ-02）" }
}

enum LocationMapRegion: String, CaseIterable, Identifiable {
    case mainlandChina, otherRegions
    var id: String { rawValue }
    var title: String { self == .mainlandChina ? "中国大陆" : "其他地区（含港澳台）" }
    var coordinateSystem: LocationCoordinateSystem { self == .mainlandChina ? .gcj02 : .wgs84 }
}

/// Forward formula adapted from MIT-licensed wandergis/coordtransform.
/// See bundled ThirdPartyLicenses.txt. The bounded iterative inverse avoids the
/// residual metres introduced by a single subtraction. This is not a geofence:
/// callers select the source system from search metadata or explicit user input.
enum LocationCoordinateConversion {
    static func convert(_ point: LocationCoordinate, from source: LocationCoordinateSystem,
                        to destination: LocationCoordinateSystem) throws -> LocationCoordinate {
        guard source != destination, supportsFormula(point) else { return point }
        if source == .wgs84 { return try forward(point) }
        var candidate = point
        for _ in 0..<10 {
            let projected = try forward(candidate)
            let latitudeError = point.latitude - projected.latitude
            let longitudeError = point.longitude - projected.longitude
            if max(abs(latitudeError), abs(longitudeError)) < 1e-9 { return candidate }
            candidate = try LocationCoordinate(latitude: candidate.latitude + latitudeError,
                                               longitude: candidate.longitude + longitudeError)
        }
        throw LocationControlError.message("坐标转换未收敛，请检查坐标类型或重新选择地点")
    }

    private static func supportsFormula(_ point: LocationCoordinate) -> Bool {
        // Numerical domain only; never use this rectangle to classify a country.
        point.longitude > 72.004 && point.longitude < 137.8347 && point.latitude > 0.8293 && point.latitude < 55.8271
    }

    private static func forward(_ point: LocationCoordinate) throws -> LocationCoordinate {
        let x = point.longitude - 105, y = point.latitude - 35, pi = Double.pi
        var latitudeDelta = -100 + 2*x + 3*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(abs(x))
        latitudeDelta += (20*sin(6*x*pi) + 20*sin(2*x*pi))*2/3
        latitudeDelta += (20*sin(y*pi) + 40*sin(y*pi/3))*2/3
        latitudeDelta += (160*sin(y*pi/12) + 320*sin(y*pi/30))*2/3
        var longitudeDelta = 300 + x + 2*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(abs(x))
        longitudeDelta += (20*sin(6*x*pi) + 20*sin(2*x*pi))*2/3
        longitudeDelta += (20*sin(x*pi) + 40*sin(x*pi/3))*2/3
        longitudeDelta += (150*sin(x*pi/12) + 300*sin(x*pi/30))*2/3
        let a = 6_378_245.0, eccentricity = 0.00669342162296594323
        let radians = point.latitude*pi/180
        let magic = 1 - eccentricity*pow(sin(radians), 2), root = sqrt(magic)
        latitudeDelta = latitudeDelta*180 / ((a*(1-eccentricity)/(magic*root))*pi)
        longitudeDelta = longitudeDelta*180 / ((a/root)*cos(radians)*pi)
        return try LocationCoordinate(latitude: point.latitude + latitudeDelta, longitude: point.longitude + longitudeDelta)
    }
}
