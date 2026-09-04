import XCTest
@testable import Earmark

final class DuplicateFinderTests: XCTestCase {
    private func book(_ title: String, sourceID: UUID, path: String, files: [String], bytes: Int64 = 100) -> Book {
        let tracks = files.map { Track(relativePath: "\(path)/\($0)", fileName: $0, title: nil, duration: 10, fileSize: bytes, modifiedAt: nil, trackNumber: nil, discNumber: nil) }
        return Book(id: Book.makeID(sourceID: sourceID, relativePath: path), sourceID: sourceID, relativePath: path, kind: .folder, title: title, author: nil, series: nil, seriesIndex: nil, narrator: nil, year: nil, tracks: tracks, chapters: [], artworkID: nil, addedAt: .now, totalBytes: bytes * Int64(files.count))
    }

    func testWholeBookDuplicatesAreGrouped() {
        let source = UUID()
        let a = book("Dune", sourceID: source, path: "Dune", files: ["1.mp3", "2.mp3"])
        let b = book("Dune (copy)", sourceID: source, path: "Copies/Dune", files: ["1.mp3", "2.mp3"])
        let c = book("Emma", sourceID: source, path: "Emma", files: ["1.mp3"])
        var fingerprints: [String: FileFingerprint] = [:]
        for (book, digests) in [(a, ["x", "y"]), (b, ["y", "x"]), (c, ["z"])] {
            for (track, digest) in zip(book.tracks, digests) {
                fingerprints[DuplicateFinder.trackKey(book.sourceID, track.relativePath)] = FileFingerprint(size: 100, digest: digest)
            }
        }
        let groups = DuplicateFinder.duplicateGroups(books: [a, b, c], fingerprints: fingerprints)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .wholeBook)
        XCTAssertEqual(Set(groups[0].books.map(\.title)), ["Dune", "Dune (copy)"])
        XCTAssertEqual(groups[0].wastedBytes, 200)
    }

    func testSharedFileAcrossDifferentBooksIsAFileGroup() {
        let source = UUID()
        let a = book("A", sourceID: source, path: "A", files: ["intro.mp3", "1.mp3"])
        let b = book("B", sourceID: source, path: "B", files: ["intro.mp3", "1.mp3"])
        var fingerprints: [String: FileFingerprint] = [:]
        fingerprints[DuplicateFinder.trackKey(source, "A/intro.mp3")] = FileFingerprint(size: 100, digest: "same")
        fingerprints[DuplicateFinder.trackKey(source, "B/intro.mp3")] = FileFingerprint(size: 100, digest: "same")
        fingerprints[DuplicateFinder.trackKey(source, "A/1.mp3")] = FileFingerprint(size: 100, digest: "a1")
        fingerprints[DuplicateFinder.trackKey(source, "B/1.mp3")] = FileFingerprint(size: 100, digest: "b1")
        let groups = DuplicateFinder.duplicateGroups(books: [a, b], fingerprints: fingerprints)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .files)
        XCTAssertEqual(groups[0].files.count, 2)
    }

    func testIncompleteFingerprintsNeverProduceABookSignature() {
        let source = UUID()
        let a = book("A", sourceID: source, path: "A", files: ["1.mp3", "2.mp3"])
        let fingerprints = [DuplicateFinder.trackKey(source, "A/1.mp3"): FileFingerprint(size: 100, digest: "x")]
        XCTAssertNil(DuplicateFinder.bookSignature(a, fingerprints: fingerprints))
    }

    func testRealFileFingerprintsMatchContentNotName() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var payload = Data(count: 700 * 1024)
        payload.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = UInt8(truncatingIfNeeded: index &* 31) }
        }
        let one = dir.appending(path: "one.mp3")
        let two = dir.appending(path: "renamed copy.mp3")
        let three = dir.appending(path: "different.mp3")
        try payload.write(to: one)
        try payload.write(to: two)
        payload[350 * 1024] ^= 0xFF
        try payload.write(to: three)

        let f1 = try DuplicateFinder.fingerprint(url: one)
        let f2 = try DuplicateFinder.fingerprint(url: two)
        let f3 = try DuplicateFinder.fingerprint(url: three)
        XCTAssertEqual(f1, f2)
        XCTAssertEqual(f1.size, Int64(700 * 1024))
        // Middle-of-file changes are outside the sampled head/tail by design; sizes still match.
        XCTAssertEqual(f1.size, f3.size)
        payload[10] ^= 0xFF
        try payload.write(to: three)
        XCTAssertNotEqual(f1, try DuplicateFinder.fingerprint(url: three))
    }
}
