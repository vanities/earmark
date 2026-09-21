import XCTest
@testable import Earmark

final class ProgressSyncTests: XCTestCase {
    private func book(id: String, path: String) -> Book {
        Book(id: id, sourceID: UUID(), relativePath: path, kind: .folder, title: id,
             tracks: [], chapters: [], addedAt: .now, totalBytes: 0)
    }
    private func progress(track: Int, time: TimeInterval, at date: Date?) -> PlaybackProgress {
        var p = PlaybackProgress(); p.trackIndex = track; p.time = time; p.lastPlayedAt = date; return p
    }

    func testCloudNewerWins() {
        let b = book(id: "srcA|Hobb/Assassin|k", path: "Hobb/Assassin")
        let local = ["srcA|Hobb/Assassin|k": progress(track: 1, time: 10, at: Date(timeIntervalSince1970: 100))]
        let cloud = ["hobb/assassin": progress(track: 5, time: 500, at: Date(timeIntervalSince1970: 200))]
        let merged = ProgressSync.merged(local: local, books: [b], cloud: cloud)
        XCTAssertEqual(merged["srcA|Hobb/Assassin|k"]?.time, 500, "newer cloud position wins")
    }

    func testLocalNewerIsKept() {
        let b = book(id: "id", path: "Hobb/Assassin")
        let local = ["id": progress(track: 9, time: 90, at: Date(timeIntervalSince1970: 300))]
        let cloud = ["hobb/assassin": progress(track: 1, time: 1, at: Date(timeIntervalSince1970: 200))]
        XCTAssertEqual(ProgressSync.merged(local: local, books: [b], cloud: cloud)["id"]?.time, 90)
    }

    func testCloudEntryAppliesToBothLocalAndDownloadedTwin() {
        // Same relative path on a remote source and the appDocuments source → same syncKey.
        let remote = book(id: "smb|Hobb/Assassin|k", path: "Hobb/Assassin")
        let localTwin = book(id: "docs|Hobb/Assassin|k", path: "Hobb/Assassin")
        let cloud = ["hobb/assassin": progress(track: 3, time: 333, at: Date(timeIntervalSince1970: 500))]
        let merged = ProgressSync.merged(local: [:], books: [remote, localTwin], cloud: cloud)
        XCTAssertEqual(merged["smb|Hobb/Assassin|k"]?.time, 333)
        XCTAssertEqual(merged["docs|Hobb/Assassin|k"]?.time, 333, "twin gets the same synced position")
    }

    func testSnapshotPreservesUnknownCloudEntries() {
        let b = book(id: "id", path: "Hobb/Assassin")
        let local = ["id": progress(track: 2, time: 22, at: Date(timeIntervalSince1970: 400))]
        let existing = ["some/other/book": progress(track: 7, time: 77, at: Date(timeIntervalSince1970: 100))]
        let snap = ProgressSync.cloudSnapshot(local: local, books: [b], existingCloud: existing)
        XCTAssertEqual(snap["hobb/assassin"]?.time, 22, "local write is in the snapshot")
        XCTAssertEqual(snap["some/other/book"]?.time, 77, "a book not on this device is preserved")
    }

    func testBooksSplitFromOneFolderDontShareProgress() {
        // One folder holding two album-tagged books: same relative path, different group keys.
        let source = UUID()
        func split(_ group: String) -> Book {
            Book(id: Book.makeID(sourceID: source, relativePath: "Box Set", groupKey: group), sourceID: source,
                 relativePath: "Box Set", kind: .folder, title: group, tracks: [], chapters: [], addedAt: .now, totalBytes: 0)
        }
        let one = split("book one"), two = split("book two")
        let cloud = [one.syncKey: progress(track: 4, time: 44, at: Date(timeIntervalSince1970: 500))]
        let merged = ProgressSync.merged(local: [:], books: [one, two], cloud: cloud)
        XCTAssertEqual(merged[one.id]?.time, 44)
        XCTAssertNil(merged[two.id], "listening to one book of a box set must not move its sibling")
    }

    func testEmptyCloudReturnsLocalUnchanged() {
        let b = book(id: "id", path: "p")
        let local = ["id": progress(track: 1, time: 5, at: .now)]
        XCTAssertEqual(ProgressSync.merged(local: local, books: [b], cloud: [:]), local)
    }
}
