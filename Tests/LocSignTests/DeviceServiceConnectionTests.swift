import XCTest
import Darwin
@testable import LocSign

final class DeviceServiceConnectionTests: XCTestCase {
    func testCloseInterruptsWaitingReceiveInsteadOfWaitingForItsTimeout() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        guard listener >= 0 else { return }
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record-pem", withExtension: "plist"))
        let connection = try await DeviceServiceConnection(host: "127.0.0.1",
            endpoint: .init(port: UInt16(bigEndian: address.sin_port), enableSSL: false),
            pairing: PairingRecord(data: Data(contentsOf: url)), timeout: 5)
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { Darwin.close(peer); connection.close() }

        let started = expectation(description: "receive task started")
        let returned = expectation(description: "pending receive interrupted")
        let receiving = Task {
            started.fulfill()
            do { _ = try await connection.receivePlist(); XCTFail("Silent peer produced a plist") }
            catch { }
            returned.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        // Let the receive reach the serial socket queue before closing it.
        try await Task.sleep(nanoseconds: 100_000_000)
        let closingStarted = ProcessInfo.processInfo.systemUptime
        connection.close()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - closingStarted, 2,
                          "Close itself must not wait for the five-second read timeout")
        await fulfillment(of: [returned], timeout: 1)
        await receiving.value
    }
}
