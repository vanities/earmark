import XCTest
@testable import Earmark

/// Removing a download must only ever take the download: never a book that lives only on this
/// iPhone, never a book in a folder the user picked, never another book sharing its folder.
final class DownloadRemovalTests: XCTestCase {
    private let nas = UUID(), documents = UUID(), picked = UUID()

    private func kind(_ book: Book) -> LibrarySource.Kind? {
        switch book.sourceID {
        case nas: .smb
        case documents: .appDocuments
        case picked: .folder
        default: nil
        }
    }

    private func book(_ path: String, in source: UUID, group: String = "", kind: Book.Kind = .folder) -> Book {
        let tracks = [Track(relativePath: kind == .folder ? "\(path)/01.mp3" : path, fileName: "01.mp3", title: nil,
                            duration: 60, fileSize: 10, modifiedAt: nil, trackNumber: 1, discNumber: nil)]
        return Book(id: Book.makeID(sourceID: source, relativePath: path, groupKey: group), sourceID: source, relativePath: path,
                    kind: kind, title: path, author: nil, series: nil, seriesIndex: nil, narrator: nil, year: nil,
                    tracks: tracks, chapters: [], artworkID: nil, addedAt: .now, totalBytes: 10)
    }

    // MARK: Which books are twins

    func testADownloadPairsWithTheNASBookItCameFrom() {
        let remote = book("Author/Dune", in: nas), local = book("Author/Dune", in: documents)
        let pairs = DownloadRemoval.pairs(in: [remote, local], kind: kind)
        XCTAssertEqual(pairs[remote.syncKey], DownloadPair(nas: remote, download: local))
    }

    func testABookOnlyOnThisIPhoneIsNeverADownload() {
        let local = book("Author/Mine", in: documents)
        XCTAssertTrue(DownloadRemoval.pairs(in: [local, book("Author/Other", in: nas)], kind: kind).isEmpty)
    }

    func testAPickedFolderIsNeverADownload() {
        let remote = book("Author/Dune", in: nas), theirs = book("Author/Dune", in: picked)
        XCTAssertTrue(DownloadRemoval.pairs(in: [remote, theirs], kind: kind).isEmpty, "a folder the user picked is theirs")
    }

    /// One folder can hold several books; the path alone would pair a download with the wrong one.
    func testBooksSharingAFolderPairByGroup() {
        let remoteA = book("Series", in: nas, group: "a"), remoteB = book("Series", in: nas, group: "b")
        let localA = book("Series", in: documents, group: "a")
        let pairs = DownloadRemoval.pairs(in: [remoteA, remoteB, localA], kind: kind)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[remoteA.syncKey]?.download, localA)
        XCTAssertNil(pairs[remoteB.syncKey], "B was never downloaded")
    }

    // MARK: What the NAS copy inherits

    func testTheNewerPlaceWins() {
        var older = PlaybackProgress(), newer = PlaybackProgress()
        older.time = 100; older.modifiedAt = Date(timeIntervalSince1970: 1_000)
        newer.time = 900; newer.modifiedAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(DownloadRemoval.place(from: newer, onto: older)?.time, 900, "listened further on the download")
        XCTAssertEqual(DownloadRemoval.place(from: older, onto: newer)?.time, 900, "the NAS copy moved on since")
        XCTAssertEqual(DownloadRemoval.place(from: nil, onto: older)?.time, 100)
        XCTAssertEqual(DownloadRemoval.place(from: newer, onto: nil)?.time, 900)
    }

    func testBookmarksFromBothCopiesKeepOneOfEachInOrder() {
        let shared = Bookmark(id: "s", offset: 50), onNAS = Bookmark(id: "n", offset: 300), onPhone = Bookmark(id: "p", offset: 10)
        let merged = DownloadRemoval.bookmarks(from: [shared, onPhone], onto: [onNAS, shared])
        XCTAssertEqual(merged.map(\.id), ["p", "s", "n"])
    }

    // MARK: What goes with the files

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "DownloadRemovalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    func testASingleFilesOwnCoverGoesButTheFoldersStaysWhileOthersListen() throws {
        let author = try tempRoot().appending(path: "Author")
        for name in ["B1.jpg", "B2.m4b", "cover.jpg"] { try touch(author.appending(path: name)) }
        DownloadRemoval.removeImages(pairedWith: author.appending(path: "B1.m4b"), in: author)
        XCTAssertFalse(exists(author.appending(path: "B1.jpg")), "B1's own cover goes with it")
        XCTAssertTrue(exists(author.appending(path: "cover.jpg")), "B2 still uses the folder's cover")
        XCTAssertTrue(exists(author.appending(path: "B2.m4b")))
    }

    func testTheLastSingleFileTakesTheFoldersCoverAndTheFolder() throws {
        let root = try tempRoot()
        let author = root.appending(path: "Author")
        try touch(author.appending(path: "cover.jpg"))
        DownloadRemoval.removeImages(pairedWith: author.appending(path: "B1.m4b"), in: author)
        DownloadRemoval.pruneEmptyFolders(from: author, bookFolder: false, root: root)
        XCTAssertFalse(exists(author))
        XCTAssertTrue(exists(root), "never Earmark's folder itself")
    }

    func testABookFolderGoesWithItsDiscsAndCoverButNotItsAuthorsOtherBooks() throws {
        let root = try tempRoot()
        let book = root.appending(path: "Author/Book")
        try FileManager.default.createDirectory(at: book.appending(path: "CD1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: book.appending(path: "CD2"), withIntermediateDirectories: true)
        try touch(book.appending(path: "cover.jpg"))
        try touch(root.appending(path: "Author/Other/01.mp3"))
        DownloadRemoval.pruneEmptyFolders(from: book, bookFolder: true, root: root)
        XCTAssertFalse(exists(book))
        XCTAssertTrue(exists(root.appending(path: "Author/Other/01.mp3")))
    }

    func testAFolderAnotherBookStillUsesStays() throws {
        let root = try tempRoot()
        let series = root.appending(path: "Series")
        try touch(series.appending(path: "b-01.mp3"))
        try touch(series.appending(path: "cover.jpg"))
        DownloadRemoval.pruneEmptyFolders(from: series, bookFolder: true, root: root)
        XCTAssertTrue(exists(series.appending(path: "b-01.mp3")))
        XCTAssertTrue(exists(series.appending(path: "cover.jpg")), "its cover is still B's")
    }

    func testNothingOutsideTheRootIsPruned() throws {
        let root = try tempRoot()
        let outside = root.deletingLastPathComponent().appending(path: "DownloadRemovalTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        DownloadRemoval.pruneEmptyFolders(from: outside, bookFolder: false, root: root)
        XCTAssertTrue(exists(outside))
    }
}
