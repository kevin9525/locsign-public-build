import XCTest
@testable import LocSign

final class LocationCoordinateConversionTests: XCTestCase {
    func testNanjingMapSelectionConvertsToDeviceCoordinateConfirmedByUser() throws {
        let map = try LocationCoordinate(latitude: 31.839047, longitude: 118.815859)
        let gps = try LocationCoordinateConversion.convert(map, from: .gcj02, to: .wgs84)
        XCTAssertEqual(gps.latitude, 31.841097105, accuracy: 0.00000001)
        XCTAssertEqual(gps.longitude, 118.810721382, accuracy: 0.00000001)
        let displayed = try LocationCoordinateConversion.convert(gps, from: .wgs84, to: .gcj02)
        XCTAssertEqual(displayed.latitude, map.latitude, accuracy: 0.00000001)
        XCTAssertEqual(displayed.longitude, map.longitude, accuracy: 0.00000001)
    }

    func testKnownBeijingForwardVectorAndInverse() throws {
        let gps = try LocationCoordinate(latitude: 39.916527, longitude: 116.397128)
        let map = try LocationCoordinateConversion.convert(gps, from: .wgs84, to: .gcj02)
        XCTAssertEqual(map.latitude, 39.91793074924595, accuracy: 0.00000001)
        XCTAssertEqual(map.longitude, 116.40337249402477, accuracy: 0.00000001)
        let restored = try LocationCoordinateConversion.convert(map, from: .gcj02, to: .wgs84)
        XCTAssertEqual(restored.latitude, gps.latitude, accuracy: 0.00000001)
        XCTAssertEqual(restored.longitude, gps.longitude, accuracy: 0.00000001)
    }

    func testExplicitMainlandCoordinatesIncludeNorthernAndWesternExtremes() throws {
        for pair in [(53.56, 123.30), (39.38, 73.50)] {
            let gps = try LocationCoordinate(latitude: pair.0, longitude: pair.1)
            let map = try LocationCoordinateConversion.convert(gps, from: .wgs84, to: .gcj02)
            XCTAssertNotEqual(map, gps)
            let restored = try LocationCoordinateConversion.convert(map, from: .gcj02, to: .wgs84)
            XCTAssertEqual(restored.latitude, gps.latitude, accuracy: 0.00000001)
            XCTAssertEqual(restored.longitude, gps.longitude, accuracy: 0.00000001)
        }
    }

    func testSameSystemAndCoordinatesOutsideSupportedAreaAreUnchanged() throws {
        for pair in [(31.839047, 118.815859), (22.3193, 114.1694), (25.0330, 121.5654), (51.5074, -0.1278)] {
            let point = try LocationCoordinate(latitude: pair.0, longitude: pair.1)
            XCTAssertEqual(try LocationCoordinateConversion.convert(point, from: .wgs84, to: .wgs84), point)
        }
        for pair in [(51.5074, -0.1278), (-33.8688, 151.2093), (0.0, 0.0)] {
            let point = try LocationCoordinate(latitude: pair.0, longitude: pair.1)
            XCTAssertEqual(try LocationCoordinateConversion.convert(point, from: .wgs84, to: .gcj02), point)
            XCTAssertEqual(try LocationCoordinateConversion.convert(point, from: .gcj02, to: .wgs84), point)
        }
    }
}
