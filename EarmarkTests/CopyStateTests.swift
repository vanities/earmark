import XCTest
@testable import Earmark

/// A book has copies — on the NAS and downloaded, in a picked folder and moved into Earmark's.
/// What the listener did to one must follow it to the other, never land on the wrong book, and
/// never undo what the copy they're looking at already has.
final class CopyStateTests: XCTestCase {
    private let nas = UUID(), documents = UUID()

    private func book(_ path: String, in source: UUID, group: String = "", kind: Book.Kind = .folder,
                      files: [String] = ["01.mp3"]) -> Book {
        let tracks = files.enumerated().map { index, name in
            Track(relativePath: kind == .folder ? "\(path)/\(name)" : path, fileName: name, title: nil,
                  duration: 60, fileSize: 10, modifiedAt: nil, trackNumber: index + 1, discNumber: nil)
        }
        return Book(id: Book.makeID(sourceID: source, relativePath: path, groupKey: group), sourceID: source, relativePath: path,
                    kind: kind, title: path, author: nil, series: nil, seriesIndex: nil, narrator: nil, year: nil,
                    tracks: tracks, chapters: [], artworkID: nil, addedAt: .now, totalBytes: 10)
    }

    private func place(_ time: TimeInterval, at stamp: TimeInterval) -> PlaybackProgress {
        var progress = PlaybackProgress()
        progress.time = time
        progress.modifiedAt = Date(timeIntervalSince1970: stamp)
        return progress
    }

    private func state(progress: [String: PlaybackProgress] = [:], bookmarks: [String: [Bookmark]] = [:],
                       corrections: [String: BookMetadataOverride] = [:], hidden: Set<String> = [], last: String? = nil) -> CopyState {
        CopyState(progress: progress, bookmarks: bookmarks, corrections: corrections, hidden: hidden, lastBookID: last)
    }

    // MARK: A copy leaves (a download removed, a book moved)

    func testEverythingFollowsTheBookWhenItMoves() {
        var copy = state(progress: ["old": place(900, at: 2_000)], bookmarks: ["old": [Bookmark(id: "b", offset: 5)]],
                         corrections: ["old": BookMetadataOverride(title: "Dune")], hidden: ["old"], last: "old")
        copy.handOver(from: "old", to: "new")
        XCTAssertEqual(copy.progress["new"]?.time, 900)
        XCTAssertEqual(copy.bookmarks["new"]?.map(\.id), ["b"])
        XCTAssertEqual(copy.corrections["new"]?.title, "Dune")
        XCTAssertEqual(copy.hidden, ["new"])
        XCTAssertEqual(copy.lastBookID, "new")
        XCTAssertNil(copy.progress["old"])
        XCTAssertNil(copy.bookmarks["old"])
        XCTAssertNil(copy.corrections["old"])
    }

    /// Corrected on the NAS, downloaded (the download took the correction), corrected again on
    /// the download, then the download removed: the second correction must survive.
    func testTheCopyBeingLookedAtKeepsItsLatestCorrections() {
        var copy = state(corrections: ["download": BookMetadataOverride(title: "Dune Messiah", author: "Frank Herbert"),
                                       "nas": BookMetadataOverride(title: "Dune", series: "Dune")])
        copy.handOver(from: "download", to: "nas")
        XCTAssertEqual(copy.corrections["nas"]?.title, "Dune Messiah", "the newer correction wins")
        XCTAssertEqual(copy.corrections["nas"]?.author, "Frank Herbert")
        XCTAssertEqual(copy.corrections["nas"]?.series, "Dune", "and one only the NAS copy had stays")
    }

    func testTheNewerPlaceWinsAndBookmarksJoin() {
        var copy = state(progress: ["download": place(100, at: 1_000), "nas": place(500, at: 2_000)],
                         bookmarks: ["download": [Bookmark(id: "d", offset: 9)], "nas": [Bookmark(id: "n", offset: 1)]])
        copy.handOver(from: "download", to: "nas")
        XCTAssertEqual(copy.progress["nas"]?.time, 500, "the NAS copy moved on since")
        XCTAssertEqual(copy.bookmarks["nas"]?.map(\.id), ["n", "d"])
    }

    // MARK: A copy arrives (a download lands)

    func testADownloadTakesWhatItLacksFromItsNASCopy() {
        var copy = state(progress: ["nas": place(300, at: 1_000)], bookmarks: ["nas": [Bookmark(id: "b", offset: 5)]],
                         corrections: ["nas": BookMetadataOverride(author: "Ursula K. Le Guin")], hidden: ["nas"], last: "nas")
        XCTAssertTrue(copy.adopt(into: "download", from: "nas"))
        XCTAssertEqual(copy.progress["download"]?.time, 300)
        XCTAssertEqual(copy.bookmarks["download"]?.map(\.id), ["b"])
        XCTAssertEqual(copy.corrections["download"]?.author, "Ursula K. Le Guin", "a correction isn't lost to a download")
        XCTAssertTrue(copy.hidden.contains("download"), "a hidden book stays hidden once downloaded")
        XCTAssertEqual(copy.lastBookID, "download")
        XCTAssertEqual(copy.progress["nas"]?.time, 300, "the NAS copy keeps its own")
    }

    func testWhatADownloadAlreadyHasIsNeverReplaced() {
        var copy = state(progress: ["nas": place(300, at: 1_000), "download": place(40, at: 3_000)],
                         corrections: ["nas": BookMetadataOverride(title: "A"), "download": BookMetadataOverride(title: "B")])
        XCTAssertFalse(copy.adopt(into: "download", from: "nas"))
        XCTAssertEqual(copy.progress["download"]?.time, 40)
        XCTAssertEqual(copy.corrections["download"]?.title, "B")
    }

    // MARK: Which NAS book a download came from

    func testTwinsMatchByKey() {
        let remote = book("Author/Dune", in: nas), arrival = book("Author/Dune", in: documents)
        XCTAssertEqual(CopyState.remoteTwins(of: [arrival], among: [remote]).map(\.twin.id), [remote.id])
    }

    /// One book of a folder that held several downloads alone, so it's grouped without a key.
    func testAnUnambiguousPathStillFindsTheTwin() {
        let remote = book("Author/Omnibus", in: nas, group: "part one"), arrival = book("Author/Omnibus", in: documents)
        XCTAssertEqual(CopyState.remoteTwins(of: [arrival], among: [remote]).map(\.twin.id), [remote.id])
    }

    /// The same book on two shares: the download takes after the one it came from.
    func testTheShareItWasDownloadedFromWins() {
        let otherShare = UUID()
        let first = book("Author/Dune", in: otherShare), source = book("Author/Dune", in: nas)
        let arrival = book("Author/Dune", in: documents)
        XCTAssertEqual(CopyState.remoteTwins(of: [arrival], among: [first, source], downloaded: [source.id]).map(\.twin.id), [source.id])
        let split = book("Author/Omnibus", in: nas, group: "part two"), other = book("Author/Omnibus", in: nas, group: "part one")
        XCTAssertEqual(CopyState.remoteTwins(of: [book("Author/Omnibus", in: documents)], among: [other, split], downloaded: [split.id])
            .map(\.twin.id), [split.id], "even where the path alone is ambiguous")
    }

    func testAnAmbiguousPathFindsNoTwinRatherThanTheWrongOne() {
        let first = book("Author/Omnibus", in: nas, group: "part one"), second = book("Author/Omnibus", in: nas, group: "part two")
        XCTAssertTrue(CopyState.remoteTwins(of: [book("Author/Omnibus", in: documents)], among: [first, second]).isEmpty)
    }

    // MARK: What moves with a book

    func testABookFolderTakesEveryImageInIt() {
        let whole = book("Author/Dune", in: documents)
        XCTAssertEqual(DownloadManager.imagesMoving(with: whole, from: ["cover.jpg", "01.mp3", "back.png", "notes.txt"]),
                       ["cover.jpg", "back.png"])
    }

    /// Books loose in one folder: each takes only its own picture, not its neighbours'.
    func testABookSharingAFolderTakesOnlyItsOwnImage() {
        let single = book("Dune.m4b", in: documents, kind: .singleFile, files: ["Dune.m4b"])
        XCTAssertEqual(DownloadManager.imagesMoving(with: single, from: ["Dune.jpg", "Emma.jpg", "cover.jpg"]), ["Dune.jpg"])
        let part = book("Author/Omnibus", in: documents, group: "part one", files: ["Part One.m4b"])
        XCTAssertEqual(DownloadManager.imagesMoving(with: part, from: ["Part One.jpg", "Part Two.jpg"]), ["Part One.jpg"])
    }
}
