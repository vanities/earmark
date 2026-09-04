import XCTest
@testable import Earmark

final class FormattingTests: XCTestCase {
    func testNaturalSort() {
        let names = ["Chapter 10", "Chapter 2", "chapter 1", "Chapter 1.5"]
        let sorted = names.sorted { $0.naturallyPrecedes($1) }
        XCTAssertEqual(sorted.first, "chapter 1")
        XCTAssertEqual(sorted.last, "Chapter 10")
        XCTAssertTrue("Disc 1/01.mp3".naturallyPrecedes("Disc 2/01.mp3"))
        XCTAssertTrue("02 - b".naturallyPrecedes("10 - a"))
    }

    func testClockAndDurationStrings() {
        XCTAssertEqual(TimeInterval(0).clockString, "0:00")
        XCTAssertEqual(TimeInterval(65).clockString, "1:05")
        XCTAssertEqual(TimeInterval(3661).clockString, "1:01:01")
        XCTAssertEqual(TimeInterval(-3).clockString, "0:00")
        XCTAssertEqual(TimeInterval(45).shortDurationString, "45s")
        XCTAssertEqual(TimeInterval(41 * 60).shortDurationString, "41m")
        XCTAssertEqual(TimeInterval(9 * 3600 + 41 * 60 + 30).shortDurationString, "9h 42m")
        XCTAssertEqual(TimeInterval(7200).shortDurationString, "2h")
        XCTAssertEqual(TimeInterval(3000).adjusted(forSpeed: 1.5), 2000, accuracy: 0.001)
    }

    func testSpeedLabel() {
        XCTAssertEqual(TransportControls.speedLabel(1.0), "1×")
        XCTAssertEqual(TransportControls.speedLabel(1.5), "1.5×")
        XCTAssertEqual(TransportControls.speedLabel(1.25), "1.25×")
    }

    func testMetadataParsers() {
        XCTAssertEqual(MetadataReader.parseFraction("3/12").0, 3)
        XCTAssertEqual(MetadataReader.parseFraction("3/12").1, 12)
        XCTAssertEqual(MetadataReader.parseFraction("7").0, 7)
        XCTAssertNil(MetadataReader.parseFraction("7").1)
        XCTAssertEqual(MetadataReader.year(from: "2004-05-01"), 2004)
        XCTAssertEqual(MetadataReader.year(from: "1997"), 1997)
        XCTAssertNil(MetadataReader.year(from: "n/a"))
    }

    func testDisplayNameCleaning() {
        XCTAssertEqual("The_Spouter__Inn ".cleanedDisplayName, "The Spouter Inn")
        XCTAssertEqual("Jane Austen".normalizedForMatching, "jane austen")
        XCTAssertTrue(BookGrouper.namesMatch("Austen, Jane", "Jane Austen"))
        XCTAssertTrue(BookGrouper.isGeneric("Audiobooks"))
        XCTAssertFalse(BookGrouper.isGeneric("Jane Austen"))
    }
}

final class NestedSourceTests: XCTestCase {
    func testDirectoryPathPrefixChecksRespectBoundaries() {
        let books = LibraryModel.directoryPath(URL(fileURLWithPath: "/x/Books"))
        let books2 = LibraryModel.directoryPath(URL(fileURLWithPath: "/x/Books 2/"))
        let nested = LibraryModel.directoryPath(URL(fileURLWithPath: "/x/Books/Austen"))
        XCTAssertEqual(books, "/x/Books/")
        XCTAssertFalse(books2.hasPrefix(books), "'Books 2' must not count as inside 'Books'")
        XCTAssertTrue(nested.hasPrefix(books))
    }
}
