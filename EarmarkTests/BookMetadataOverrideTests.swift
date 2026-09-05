import XCTest
@testable import Earmark

final class BookMetadataOverrideTests: XCTestCase {
    private func book() -> Book {
        Book(id: "s|p|k", sourceID: UUID(), relativePath: "p", kind: .folder,
             title: "Detected Title", author: "Detected Author", series: "Detected Series",
             seriesIndex: 1, narrator: "Detected Narrator", year: 2001,
             tracks: [], chapters: [], addedAt: .now, totalBytes: 0)
    }

    func testAppliesOnlySetFields() {
        var o = BookMetadataOverride(); o.title = "Real Title"; o.seriesIndex = 3
        let b = o.applied(to: book())
        XCTAssertEqual(b.title, "Real Title")
        XCTAssertEqual(b.seriesIndex, 3)
        XCTAssertEqual(b.author, "Detected Author", "untouched fields stay detected")
        XCTAssertEqual(b.series, "Detected Series")
    }

    func testEmptyStringClearsField() {
        var o = BookMetadataOverride(); o.series = ""; o.narrator = ""
        let b = o.applied(to: book())
        XCTAssertNil(b.series)
        XCTAssertNil(b.seriesIndex, "clearing the series clears its index")
        XCTAssertNil(b.narrator)
    }

    func testTitleNeverClears() {
        var o = BookMetadataOverride(); o.title = ""
        XCTAssertEqual(o.applied(to: book()).title, "Detected Title")
    }

    func testMergeLayersNewerOverOlder() {
        var older = BookMetadataOverride(); older.author = "Fixed Author"; older.series = "Fixed Series"
        var newer = BookMetadataOverride(); newer.series = "Newer Series"
        let m = older.merged(with: newer)
        XCTAssertEqual(m.author, "Fixed Author", "kept from older")
        XCTAssertEqual(m.series, "Newer Series", "newer wins")
    }

    func testRoundTripsThroughLibraryState() throws {
        var state = LibraryState()
        var o = BookMetadataOverride(); o.author = "Corrected"
        state.metadataOverrides = ["s|p|k": o]
        let data = try { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return try e.encode(state) }()
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(LibraryState.self, from: data)
        XCTAssertEqual(back.metadataOverrides["s|p|k"]?.author, "Corrected")
    }
}
