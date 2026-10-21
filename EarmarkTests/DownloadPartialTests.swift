import Foundation
import XCTest
@testable import Earmark

final class DownloadPartialTests: XCTestCase {
    private func source(endpoint: String = "nas-a", path: String = "book.cbz", size: Int64 = 10,
                        date: Date? = Date(timeIntervalSince1970: 100), sample: String = "sample-a") -> DownloadPartial.Source {
        .init(endpoint: endpoint, path: path, size: size, modifiedAt: date, sampleFingerprint: sample)
    }

    private func withFiles(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DownloadPartial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let final = root.appending(path: "book.cbz")
        try body(final, final.appendingPathExtension("part"))
    }

    func testUnchangedSourceRetainsVerifiedPartialAcrossPreparation() throws {
        try withFiles { _, partial in
            _ = try DownloadPartial.prepare(at: partial, source: source())
            let bytes = Data([1, 2, 3, 4])
            try bytes.write(to: partial)
            let prepared = try DownloadPartial.prepare(at: partial, source: source())
            XCTAssertEqual(try Data(contentsOf: partial), bytes)
            XCTAssertEqual(prepared.retainedBytes, 4)
            XCTAssertFalse(prepared.isComplete)
        }
    }

    func testChangedSourceDiscardsPartialWithoutTouchingCompletedFile() throws {
        try withFiles { final, partial in
            let completed = Data("previous completed book".utf8)
            try completed.write(to: final)
            _ = try DownloadPartial.prepare(at: partial, source: source())
            try Data([1, 2, 3, 4]).write(to: partial)
            let prepared = try DownloadPartial.prepare(at: partial, source: source(date: Date(timeIntervalSince1970: 200), sample: "sample-b"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertEqual(prepared.retainedBytes, 0)
            XCTAssertEqual(try Data(contentsOf: final), completed)
        }
    }

    func testChangedSamplesRejectReplacementWithPreservedTimestamp() throws {
        try withFiles { _, partial in
            _ = try DownloadPartial.prepare(at: partial, source: source())
            try Data([1, 2, 3, 4]).write(to: partial)
            _ = try DownloadPartial.prepare(at: partial, source: source(sample: "replacement"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        }
    }

    func testLegacyPartialWithoutSourceRecordStartsOver() throws {
        try withFiles { _, partial in
            try Data([1, 2, 3, 4]).write(to: partial)
            let prepared = try DownloadPartial.prepare(at: partial, source: source())
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertEqual(prepared.retainedBytes, 0)
        }
    }

    func testMissingTimestampNeverEstablishesAResumableVersion() throws {
        try withFiles { _, partial in
            let unknown = source(date: nil)
            _ = try DownloadPartial.prepare(at: partial, source: unknown)
            try Data([1, 2, 3, 4]).write(to: partial)
            _ = try DownloadPartial.prepare(at: partial, source: unknown)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        }
    }

    func testOversizedPartialIsNotAcceptedAsComplete() throws {
        try withFiles { _, partial in
            _ = try DownloadPartial.prepare(at: partial, source: source())
            try Data(repeating: 7, count: 11).write(to: partial)
            let prepared = try DownloadPartial.prepare(at: partial, source: source())
            XCTAssertFalse(prepared.isComplete)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        }
    }

    func testCorruptRecordDoesNotAuthorizeResume() throws {
        try withFiles { _, partial in
            _ = try DownloadPartial.prepare(at: partial, source: source())
            try Data([1, 2, 3, 4]).write(to: partial)
            try Data("not a source record".utf8).write(to: DownloadPartial.metadataURL(for: partial))
            _ = try DownloadPartial.prepare(at: partial, source: source())
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        }
    }

    func testACompleteVerifiedPartialCanBePromotedWithoutAnotherDownload() throws {
        try withFiles { _, partial in
            _ = try DownloadPartial.prepare(at: partial, source: source())
            try Data(repeating: 7, count: 10).write(to: partial)
            let prepared = try DownloadPartial.prepare(at: partial, source: source())
            XCTAssertTrue(prepared.isComplete)
            XCTAssertEqual(prepared.retainedBytes, 10)
        }
    }

    func testChangingEndpointOrPathCannotReuseAnotherSourcesPartial() throws {
        for replacement in [source(endpoint: "nas-b"), source(path: "different.cbz")] {
            try withFiles { _, partial in
                _ = try DownloadPartial.prepare(at: partial, source: source())
                try Data([1, 2, 3, 4]).write(to: partial)
                _ = try DownloadPartial.prepare(at: partial, source: replacement)
                XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            }
        }
    }
}
