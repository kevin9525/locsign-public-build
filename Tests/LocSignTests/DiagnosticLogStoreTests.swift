import XCTest
@testable import LocSign

final class DiagnosticLogStoreTests: XCTestCase {
    func testMissingLogIsEmptyAndReadingDoesNotCreateIt() async throws {
        let url = try logURL()
        let text = try await DiagnosticLogStore(fileURL: url).snapshot()
        XCTAssertEqual(text, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSnapshotIncludesQueuedWritesAndReopenedStoreKeepsThem() async throws {
        let url = try logURL()
        let store = DiagnosticLogStore(fileURL: url)
        store.append("first")
        store.append("第二条")
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot, "first\n第二条\n")
        let reopened = try await DiagnosticLogStore(fileURL: url).snapshot()
        XCTAssertEqual(reopened, snapshot)
    }

    func testRotationKeepsNewestCompleteUTF8LinesWithinDiskAndSnapshotLimits() async throws {
        let url = try logURL()
        let store = DiagnosticLogStore(fileURL: url, maximumFileBytes: 512, maximumSnapshotBytes: 128)
        for index in 0..<80 { store.append("记录-\(index)-定位操作完成") }
        let snapshot = try await store.snapshot()
        let disk = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(disk.count, 512)
        XCTAssertLessThanOrEqual(snapshot.utf8.count, 128)
        XCTAssertNotNil(String(data: disk, encoding: .utf8))
        XCTAssertTrue(snapshot.hasSuffix("记录-79-定位操作完成\n"))
        XCTAssertFalse(snapshot.contains("记录-0-"))
        XCTAssertFalse(snapshot.contains("�"))
        XCTAssertTrue(snapshot.split(separator: "\n").allSatisfy { $0.hasPrefix("记录-") })
    }

    func testOldOversizedLogCanBeReadAndNextWriteBoundsDiskUsage() async throws {
        let url = try logURL()
        let original = String(repeating: "2026-11-26 01:00:00 +0000 [INFO] 旧日志内容\n", count: 50_000)
            + "2026-11-26 01:00:01 +0000 [INFO] latest-before-update\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let store = DiagnosticLogStore(fileURL: url, maximumFileBytes: 512, maximumSnapshotBytes: 128)
        let before = try await store.snapshot()
        XCTAssertTrue(before.hasSuffix("latest-before-update\n"))
        XCTAssertLessThanOrEqual(before.utf8.count, 128)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "Viewing must not rewrite old logs")
        store.append("after-update")
        let after = try await store.snapshot()
        XCTAssertTrue(after.hasSuffix("after-update\n"))
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 512)
    }

    func testSensitiveEntryIsRedactedBeforeOversizedEntryIsTruncated() async throws {
        let url = try logURL()
        let store = DiagnosticLogStore(fileURL: url, maximumFileBytes: 512, maximumSnapshotBytes: 256)
        store.append("should-not-leak-" + String(repeating: "x", count: 2_000) + " password=synthetic-secret")
        let snapshot = try await store.snapshot()
        XCTAssertFalse(snapshot.contains("should-not-leak"))
        XCTAssertFalse(snapshot.contains("synthetic-secret"))
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("synthetic-secret"))
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testOversizedUTF8EntryStillLeavesRoomForTheNextRecord() async throws {
        let url = try logURL()
        let store = DiagnosticLogStore(fileURL: url, maximumFileBytes: 512, maximumSnapshotBytes: 256)
        store.append(String(repeating: "定位", count: 4_000))
        store.append("next-record")
        let snapshot = try await store.snapshot()
        let disk = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(disk.count, 512)
        XCTAssertNotNil(String(data: disk, encoding: .utf8))
        XCTAssertTrue(snapshot.hasSuffix("next-record\n"))
        XCTAssertFalse(snapshot.contains("�"))
    }

    func testLegacySensitiveLinesAndPrivateKeyBodyAreHiddenAgainWhenReading() async throws {
        let url = try logURL()
        let original = """
        safe-before
        account=user@example.com
        -----BEGIN RSA PRIVATE KEY-----
        synthetic-key-body
        -----END RSA PRIVATE KEY-----
        Authorization: Bearer synthetic-token
        device=00008110-00123456789ABCDE
        safe-after

        """
        try original.write(to: url, atomically: true, encoding: .utf8)
        let snapshot = try await DiagnosticLogStore(fileURL: url).snapshot()
        for secret in ["user@example.com", "synthetic-key-body", "synthetic-token", "00123456789ABCDE"] {
            XCTAssertFalse(snapshot.contains(secret))
        }
        XCTAssertTrue(snapshot.contains("safe-before"))
        XCTAssertTrue(snapshot.contains("safe-after"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testUnfinishedLegacyPrivateKeyIsHiddenThroughEndOfFile() async throws {
        let url = try logURL()
        try "safe\n-----BEGIN PRIVATE KEY-----\nsynthetic-incomplete-body\n".write(to: url, atomically: true, encoding: .utf8)
        let snapshot = try await DiagnosticLogStore(fileURL: url).snapshot()
        XCTAssertTrue(snapshot.contains("safe"))
        XCTAssertFalse(snapshot.contains("synthetic-incomplete-body"))
    }

    func testTruncatedLegacyReadDoesNotExposeAnUnterminatedPrivateKeyBody() async throws {
        let url = try logURL()
        let privateBlock = "-----BEGIN PRIVATE KEY-----\n" + String(repeating: "synthetic-key-body\n", count: 100)
        try privateBlock.write(to: url, atomically: true, encoding: .utf8)
        let store = DiagnosticLogStore(fileURL: url, maximumFileBytes: 512, maximumSnapshotBytes: 256)
        let snapshot = try await store.snapshot()
        XCTAssertFalse(snapshot.contains("synthetic-key-body"))
        store.append("2026-11-26 01:00:00 +0000 [INFO] recovered")
        let after = try await store.snapshot()
        XCTAssertTrue(after.contains("recovered"))
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("synthetic-key-body"))
    }

    func testNewEntryStartsOnANewLineAfterAnInterruptedLegacyWrite() async throws {
        let url = try logURL()
        try "old-record-without-newline".write(to: url, atomically: true, encoding: .utf8)
        let store = DiagnosticLogStore(fileURL: url)
        store.append("new-record")
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot, "old-record-without-newline\nnew-record\n")
    }

    func testConcurrentWritersProduceWholeRecords() async throws {
        let store = DiagnosticLogStore(fileURL: try logURL())
        DispatchQueue.concurrentPerform(iterations: 100) { store.append("record-\($0)") }
        let snapshot = try await store.snapshot()
        let lines = snapshot.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 100)
        XCTAssertEqual(Set(lines), Set((0..<100).map { "record-\($0)" }))
    }

    func testUnreadablePathIsAnErrorInsteadOfAnEmptyLog() async throws {
        let url = try logURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            _ = try await DiagnosticLogStore(fileURL: url).snapshot()
            XCTFail("A directory is not an empty log")
        } catch {}
    }

    func testWriteFailureIsReportedAndSuccessfulWriteRecovers() async throws {
        let url = try logURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = DiagnosticLogStore(fileURL: url)
        store.append("cannot-write")
        do {
            _ = try await store.snapshot()
            XCTFail("Failed persistence must be visible")
        } catch {}
        try FileManager.default.removeItem(at: url)
        store.append("recovered")
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot, "recovered\n")
    }

    private func logURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("app.log")
    }
}
