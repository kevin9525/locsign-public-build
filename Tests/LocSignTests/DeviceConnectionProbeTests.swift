import XCTest
import Network
@testable import LocSign

final class DeviceConnectionProbeTests: XCTestCase {
    func testNonRespondingDeviceUsesShortReadinessDeadline() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let queue = DispatchQueue(label: "com.locsign.tests.silent-device")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                // Keep the accepted peer alive but do not answer QueryType.
                queue.asyncAfter(deadline: .now() + 3) { connection.cancel() }
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let start = Date()
        do {
            _ = try await DeviceConnectionProbe().check(host: "127.0.0.1", port: XCTUnwrap(listener.port).rawValue, timeout: 0.15)
            XCTFail("Silent device must not be considered ready")
        } catch { XCTAssertTrue(error is LocSignError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testLocalServerRespondsWithExpectedService() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let queue = DispatchQueue(label: "com.locsign.tests.server")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        let response = try PlistFrame.encode(["Type": "com.apple.mobile.lockdown"])
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port).rawValue
        let result = try await DeviceConnectionProbe().check(host: "127.0.0.1", port: port)
        XCTAssertEqual(result.service, "com.apple.mobile.lockdown")
    }

    func testAlreadyCancelledProbeDoesNotConnect() async {
        let probe = DeviceConnectionProbe()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await probe.check(host: "127.0.0.1", port: 1)
        }
        do {
            _ = try await task.value
            XCTFail("已取消的探测不能返回成功")
        } catch is CancellationError {
            // Expected before opening a socket.
        } catch { XCTFail("应返回 CancellationError，实际为 \(error)") }
    }

    func testURLIsNotAcceptedAsDeviceAddress() async {
        do {
            _ = try await DeviceConnectionProbe().check(host: "https://example.com/")
            XCTFail("地址不能是 URL")
        } catch {
            XCTAssertTrue(error is LocSignError)
        }
    }
}
