import XCTest
@testable import Earmark

/// Find Cover reads the same catalogs as Look Up (`Catalogs`); these are shapes they actually send.
final class CoverSearchTests: XCTestCase {
    func testAppleAudiobooksComeBackFullSize() {
        let json = #"{"resultCount":1,"results":[{"collectionId":42,"collectionName":"Moby-Dick (Unabridged)","artistName":"Herman Melville","artworkUrl100":"https://example.com/art/100x100bb.jpg"}]}"#
        let candidate = CoverSearch.appleCandidates(Data(json.utf8), media: "audiobook", query: "Moby-Dick").first
        XCTAssertEqual(candidate?.id, "apple-audiobook-42")
        XCTAssertEqual(candidate?.thumbnailURL.absoluteString, "https://example.com/art/100x100bb.jpg")
        XCTAssertEqual(candidate?.fullURL.absoluteString, "https://example.com/art/1200x1200bb.jpg")
        XCTAssertEqual(candidate?.source, "Apple Books · Audiobook")
    }

    /// Ebooks name themselves with `track…` rather than `collection…`; one without art is skipped.
    func testAppleEbooksUseTrackFields() {
        let json = #"{"results":[{"trackId":7,"trackName":"Dune","artistName":"Frank Herbert","artworkUrl100":"https://example.com/d/100x100bb.jpg"},{"trackId":8,"trackName":"No Art"}]}"#
        let candidates = CoverSearch.appleCandidates(Data(json.utf8), media: "ebook", query: "Dune")
        XCTAssertEqual(candidates.map(\.id), ["apple-ebook-7"])
        XCTAssertEqual(candidates.first?.title, "Dune")
        XCTAssertEqual(candidates.first?.source, "Apple Books")
    }

    func testOpenLibraryCoversOnlyWhenThereIsOne() {
        let json = #"{"docs":[{"title":"Frankenstein","author_name":["Mary Shelley"],"cover_i":7},{"title":"No Cover"}]}"#
        let candidates = CoverSearch.openLibraryCandidates(Data(json.utf8), title: "Frankenstein")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.author, "Mary Shelley")
        XCTAssertEqual(candidates.first?.thumbnailURL.absoluteString, "https://covers.openlibrary.org/b/id/7-M.jpg")
        XCTAssertEqual(candidates.first?.fullURL.absoluteString, "https://covers.openlibrary.org/b/id/7-L.jpg")
    }

    func testAnUnexpectedAnswerIsNoCandidatesNotACrash() {
        XCTAssertTrue(CoverSearch.appleCandidates(Data("<html>".utf8), media: "audiobook", query: "x").isEmpty)
        XCTAssertTrue(CoverSearch.openLibraryCandidates(Data("{}".utf8), title: "x").isEmpty)
    }
}
