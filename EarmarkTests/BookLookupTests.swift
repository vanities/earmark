import XCTest
@testable import Earmark

/// Look Up reads what real catalogs return; these are shapes they actually send.
final class BookLookupTests: XCTestCase {
    func testASeriesInTheTitleIsSplitOut() {
        let parts = BookLookup.splitTitle("The Way of Kings: The Stormlight Archive, Book 1 (Unabridged)")
        XCTAssertEqual(parts.title, "The Way of Kings")
        XCTAssertEqual(parts.series, "The Stormlight Archive")
        XCTAssertEqual(parts.index, 1)
    }

    func testTheParenthesisedFormToo() {
        let parts = BookLookup.splitTitle("Dragon Keeper (The Rain Wild Chronicles, Book 1)")
        XCTAssertEqual(parts.title, "Dragon Keeper")
        XCTAssertEqual(parts.series, "The Rain Wild Chronicles")
        XCTAssertEqual(parts.index, 1)
    }

    func testASubtitleThatIsNotASeriesStays() {
        let parts = BookLookup.splitTitle("Sapiens: A Brief History of Humankind [Unabridged]")
        XCTAssertEqual(parts.title, "Sapiens: A Brief History of Humankind")
        XCTAssertNil(parts.series)
    }

    func testAppleResults() {
        let json = #"{"resultCount":1,"results":[{"collectionId":42,"collectionName":"Moby-Dick (Unabridged)","artistName":"Herman Melville","releaseDate":"2011-06-01T07:00:00Z","artworkUrl100":"https://example.com/a.jpg"}]}"#
        let match = BookLookup.parseApple(Data(json.utf8)).first
        XCTAssertEqual(match?.title, "Moby-Dick")
        XCTAssertEqual(match?.author, "Herman Melville")
        XCTAssertEqual(match?.year, 2011)
        XCTAssertEqual(match?.source, "Apple Books")
    }

    func testOpenLibraryResults() {
        let json = #"{"docs":[{"key":"/works/OL1W","title":"Frankenstein","author_name":["Mary Shelley"],"first_publish_year":1818,"cover_i":7}]}"#
        let match = BookLookup.parseOpenLibrary(Data(json.utf8)).first
        XCTAssertEqual(match?.title, "Frankenstein")
        XCTAssertEqual(match?.year, 1818)
        XCTAssertEqual(match?.artworkURL?.absoluteString, "https://covers.openlibrary.org/b/id/7-S.jpg")
    }

    func testAnAudiobookArtistSplitsIntoAuthorAndNarrator() {
        let split = BookLookup.splitArtist("Herman Melville & Kathleen Olmstead", knownAuthor: "herman melville")
        XCTAssertEqual(split.author, "Herman Melville")
        XCTAssertEqual(split.narrator, "Kathleen Olmstead")
        XCTAssertNil(BookLookup.splitArtist("Classic Audiobooks & Hörbücher", knownAuthor: "Herman Melville").narrator,
                     "only when the first part is the author already known")
        XCTAssertNil(BookLookup.splitArtist("Herman Melville & Kathleen Olmstead", knownAuthor: "").narrator)
    }

    /// Catalogs answer loosely; only matches with every searched word count, each once.
    func testOnlyMatchesWithEveryWordAreKept() {
        let dune = BookMatch(id: "1", title: "Dune", author: "Frank Herbert", artworkURL: nil, source: "Apple Books")
        let buggy = BookMatch(id: "2", title: "Dune Buggy Repair", author: "Someone Else", artworkURL: nil, source: "Open Library")
        let again = BookMatch(id: "3", title: "Dune", author: "Frank Herbert", artworkURL: nil, source: "Open Library")
        XCTAssertEqual(BookLookup.relevant([dune, buggy, again], to: "Dune Herbert").map(\.id), ["1"])
    }
}
