import XCTest
@testable import Earmark

/// A shelf's page offers one book to play: the one you were on there, else the first one you
/// haven't finished, in the page's order.
final class NextUpTests: XCTestCase {
    private let source = UUID()

    private func book(_ title: String) -> Book {
        Book(id: Book.makeID(sourceID: source, relativePath: title), sourceID: source, relativePath: title, kind: .folder,
             title: title, author: "Dennis E. Taylor", series: "Bobiverse", seriesIndex: nil, narrator: nil, year: nil,
             tracks: [], chapters: [], artworkID: nil, addedAt: .now, totalBytes: 0)
    }

    func testResumesTheBookPlayedLast() {
        let books = ["One", "Two", "Three"].map(book)
        let progress = [books[0].id: PlaybackProgress(lastPlayedAt: Date(timeIntervalSince1970: 100)),
                        books[2].id: PlaybackProgress(lastPlayedAt: Date(timeIntervalSince1970: 200))]
        let next = NextUp.pick(in: books) { progress[$0] }
        XCTAssertEqual(next?.book.title, "Three")
        XCTAssertEqual(next?.resuming, true)
    }

    /// A finished book isn't one to resume, however recently it played.
    func testOtherwiseStartsTheFirstUnfinishedInOrder() {
        let books = ["One", "Two", "Three"].map(book)
        let progress = [books[0].id: PlaybackProgress(lastPlayedAt: .now, isFinished: true)]
        let next = NextUp.pick(in: books) { progress[$0] }
        XCTAssertEqual(next?.book.title, "Two")
        XCTAssertEqual(next?.resuming, false)
    }

    func testNothingWhenEveryBookIsFinished() {
        let books = ["One", "Two"].map(book)
        let progress = Dictionary(uniqueKeysWithValues: books.map { ($0.id, PlaybackProgress(lastPlayedAt: .now, isFinished: true)) })
        XCTAssertNil(NextUp.pick(in: books) { progress[$0] })
    }
}
