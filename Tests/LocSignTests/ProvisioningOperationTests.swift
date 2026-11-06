import XCTest
@testable import LocSign

final class ProvisioningOperationTests: XCTestCase {
    func testOnlyLatestOperationIsCurrent() async {
        let operation = ProvisioningOperation()
        let first = await operation.begin()
        let second = await operation.begin()

        let firstIsCurrent = await operation.isCurrent(first)
        let secondIsCurrent = await operation.isCurrent(second)
        XCTAssertFalse(firstIsCurrent)
        XCTAssertTrue(secondIsCurrent)
        let cancelled = await operation.cancel()
        let cancelledIsCurrent = await operation.isCurrent(cancelled)
        let secondAfterCancelIsCurrent = await operation.isCurrent(second)
        XCTAssertTrue(cancelledIsCurrent)
        XCTAssertFalse(secondAfterCancelIsCurrent)
    }

    func testLateResponseCannotCommitAfterCancel() async throws {
        let operation = ProvisioningOperation()
        let old = await operation.begin()
        _ = await operation.cancel()
        let recorder = CommitRecorder()

        do {
            try await operation.commit(old) { recorder.record() }
            XCTFail("A cancelled response must not commit credentials")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? ProvisioningError) == .cancelled)
        }
        XCTAssertEqual(recorder.count, 0)
    }

    func testCurrentOperationCanCommit() async throws {
        let operation = ProvisioningOperation()
        let current = await operation.begin()
        let recorder = CommitRecorder()
        try await operation.commit(current) { recorder.record() }
        XCTAssertEqual(recorder.count, 1)
    }
}

private final class CommitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
