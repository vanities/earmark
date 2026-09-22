import XCTest
@testable import Earmark

/// Lists hold books by path, so nothing on one ever drops out because a book was downloaded,
/// rescanned, or read on another device.
final class BookListTests: XCTestCase {
    func testAddingTwiceKeepsOneInItsPlace() {
        var lists = [BookList(name: "Up next")]
        let id = lists[0].id
        lists.add("dune", to: id)
        lists.add("emma", to: id)
        lists.add("dune", to: id)
        XCTAssertEqual(lists[0].items, ["dune", "emma"])
    }

    func testRemovingAndReordering() {
        var lists = [BookList(name: "Road trip", items: ["a", "b", "c"])]
        let id = lists[0].id
        lists.move(in: id, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(lists[0].items, ["c", "a", "b"])
        lists.remove("a", from: id)
        XCTAssertEqual(lists[0].items, ["c", "b"])
    }

    /// A downloaded book and its NAS copy share a path: listed as either, it's the same entry.
    func testAListedBookIsItsDownloadToo() {
        let nas = Book(id: Book.makeID(sourceID: UUID(), relativePath: "Author/Dune"), sourceID: UUID(), relativePath: "Author/Dune",
                       kind: .folder, title: "Dune", author: nil, series: nil, seriesIndex: nil, narrator: nil, year: nil,
                       tracks: [], chapters: [], artworkID: nil, addedAt: .now, totalBytes: 0)
        var download = nas
        download.sourceID = UUID()
        XCTAssertEqual(nas.syncKey, download.syncKey)
    }

    func testListsAreSavedAndOldLibrariesStillLoad() throws {
        var state = LibraryState()
        state.bookLists = [BookList(name: "Up next", items: ["author/dune"])]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(LibraryState.self, from: encoder.encode(state)).bookLists.first?.items, ["author/dune"])
        XCTAssertTrue(try decoder.decode(LibraryState.self, from: Data(#"{"progress":{}}"#.utf8)).bookLists.isEmpty)
    }

    func testRestoringAnOldLibraryBringsBackItsLists() {
        var current = LibraryState()
        let kept = BookList(name: "Kept")
        current.bookLists = [kept]
        var old = LibraryState()
        old.bookLists = [kept, BookList(name: "Lost")]
        current.merge(restoring: old)
        XCTAssertEqual(current.bookLists.map(\.name), ["Kept", "Lost"])
    }
}
