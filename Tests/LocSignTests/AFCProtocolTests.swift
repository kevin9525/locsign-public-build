import XCTest
@testable import LocSign

final class AFCProtocolTests: XCTestCase {
    func testAFCFrameUsesLittleEndianHeaderAndRoundTrips() throws {
        let frame = AFCFrame.write(handle: 7, data: Data("ipa".utf8), packetNumber: 4)
        let encoded = try frame.encoded()
        XCTAssertEqual(String(data: encoded.prefix(8), encoding: .ascii), "CFA6LPAA")
        XCTAssertEqual(encoded[8], 51)
        XCTAssertEqual(encoded[16], 48)
        let decoded = try AFCFrame.decode(encoded)
        XCTAssertEqual(decoded.operation, .write)
        XCTAssertEqual(decoded.packetNumber, 4)
        XCTAssertEqual(decoded.payload, Data([7, 0, 0, 0, 0, 0, 0, 0]) + Data("ipa".utf8))
        XCTAssertEqual(decoded.thisLength, 48)
    }

    func testInstallationProgressReportsCompletionAndRejectsBadProgress() throws {
        let request = InstallationProxyProtocol.installRequest(packagePath: "/PublicStaging/app.ipa")
        XCTAssertEqual(request["Command"] as? String, "Install")
        XCTAssertEqual(request["PackagePath"] as? String, "/PublicStaging/app.ipa")
        XCTAssertTrue(try InstallationProxyProtocol.progress(from: ["Status": "Installing", "PercentComplete": 50]).complete == false)
        XCTAssertTrue(try InstallationProxyProtocol.progress(from: ["Status": "Complete", "PercentComplete": 100]).complete)
        XCTAssertThrowsError(try InstallationProxyProtocol.progress(from: ["PercentComplete": 101]))
        XCTAssertThrowsError(try InstallationProxyProtocol.progress(from: ["PercentComplete": 50]))
    }

    func testFileOpenResultAcceptsAFCDataPayload() throws {
        let bytes = Data([42, 0, 0, 0, 0, 0, 0, 0])
        let response = AFCFrame(operation: .data, packetNumber: 1, payload: bytes, thisLength: nil)
        XCTAssertEqual(try AFCFrame.openedHandle(from: response), 42)
    }

    func testMakeDirectoryEncodesNulTerminatedAFCPath() throws {
        let path = "/PublicStaging/LocSign-session"
        let decoded = try AFCFrame.decode(AFCFrame.makeDirectory(path: path, packetNumber: 9).encoded())

        XCTAssertEqual(decoded.operation, .makeDirectory)
        XCTAssertEqual(decoded.packetNumber, 9)
        XCTAssertEqual(decoded.payload, Data(path.utf8) + Data([0]))
    }
}
