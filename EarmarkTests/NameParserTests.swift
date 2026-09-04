import XCTest
@testable import Earmark

/// Real names from a real BookPlayer library.
final class NameParserTests: XCTestCase {
    func testAuthorSeriesBookTitle() {
        let parsed = NameParser.parse("James S. A. Corey - Captive's War, Book 2 - The Faith of Beasts")
        XCTAssertEqual(parsed.author, "James S. A. Corey")
        XCTAssertEqual(parsed.series, "Captive's War")
        XCTAssertEqual(parsed.seriesIndex, 2)
        XCTAssertEqual(parsed.title, "The Faith of Beasts")
    }

    func testTitleColonSeriesBookWithModifierColon() {
        let parsed = NameParser.parse("Station Eternity꞉ The Midsolar Murders, Book 1")
        XCTAssertEqual(parsed.title, "Station Eternity")
        XCTAssertEqual(parsed.series, "The Midsolar Murders")
        XCTAssertEqual(parsed.seriesIndex, 1)
        XCTAssertNil(parsed.author)
    }

    func testAuthorSeriesNumberTitleWithBitrateJunk() {
        let parsed = NameParser.parse("Roger Zelazny - Amber 03 - Sign of the Unicornr (48 KBps Unabridged)")
        XCTAssertEqual(parsed.author, "Roger Zelazny")
        XCTAssertEqual(parsed.series, "Amber")
        XCTAssertEqual(parsed.seriesIndex, 3)
        XCTAssertEqual(parsed.title, "Sign of the Unicornr")
    }

    func testTrailingNarratorInParens() {
        let parsed = NameParser.parse("Matt Dinniman - Dungeon Crawler Carl 01 - Dungeon Crawler Carl (Jeff Hays)")
        XCTAssertEqual(parsed.narrator, "Jeff Hays")
        XCTAssertEqual(parsed.author, "Matt Dinniman")
        XCTAssertEqual(parsed.series, "Dungeon Crawler Carl")
        XCTAssertEqual(parsed.seriesIndex, 1)
        XCTAssertEqual(parsed.title, "Dungeon Crawler Carl")
    }

    func testReadBy() {
        let parsed = NameParser.parse("Don Quixote - read by George Guidall")
        XCTAssertEqual(parsed.title, "Don Quixote")
        XCTAssertEqual(parsed.narrator, "George Guidall")
        XCTAssertNil(parsed.author)
    }

    func testTwoPartNamesEitherOrder() {
        XCTAssertEqual(NameParser.parse("Morals and Dogma - Albert Pike"), NameParser.Parsed(title: "Morals and Dogma", author: "Albert Pike"))
        XCTAssertEqual(NameParser.parse("Joe Abercrombie - The Devils"), NameParser.Parsed(title: "The Devils", author: "Joe Abercrombie"))
        XCTAssertEqual(NameParser.parse("The Iliad - Homer Emily Wilson").author, "Homer Emily Wilson")
        XCTAssertEqual(NameParser.parse("Dune - Frank Herbert").author, "Frank Herbert")
        XCTAssertEqual(NameParser.parse("Dune - Frank Herbert").title, "Dune")
    }

    func testKnownAuthorDisambiguates() {
        let parsed = NameParser.parse("Blood Meridian - Cormac McCarthy", knownAuthor: "Cormac McCarthy")
        XCTAssertEqual(parsed.title, "Blood Meridian")
        XCTAssertEqual(parsed.author, "Cormac McCarthy")
    }

    func testJunkStripping() {
        XCTAssertEqual(NameParser.clean("Life 3.0 Being Human in the Age of Artificial Intelligence (Unabridged)"), "Life 3.0 Being Human in the Age of Artificial Intelligence")
        XCTAssertEqual(NameParser.clean("Zelazny -- Chronicles of Amber -- 48kbps unabr"), "Zelazny - Chronicles of Amber")
        XCTAssertEqual(NameParser.clean("Stranger in a Strange Land [Uncut] by Robert A. Heinlein"), "Stranger in a Strange Land by Robert A. Heinlein")
        XCTAssertEqual(NameParser.cleanSeriesName("James S. A. Corey - The Expanse Series"), "James S. A. Corey - The Expanse")
        XCTAssertEqual(NameParser.cleanSeriesName("Malazan Book of the Fallen Series Books 01-10"), "Malazan Book of the Fallen")
    }

    func testSeriesRemovingAuthor() {
        XCTAssertEqual(NameParser.seriesRemovingAuthor("James S. A. Corey", from: "James S. A. Corey - The Expanse Series"), "The Expanse")
        XCTAssertEqual(NameParser.seriesRemovingAuthor("Roger Zelazny", from: "Zelazny -- Chronicles of Amber -- 48kbps unabr"), "Chronicles of Amber")
        XCTAssertEqual(NameParser.seriesRemovingAuthor("Steven Erikson", from: "Steven Erikson - Malazan Book of the Fallen Series Books 01-10"), "Malazan Book of the Fallen")
        XCTAssertNil(NameParser.seriesRemovingAuthor("Robin Hobb", from: "Robin Hobb"))
        XCTAssertTrue(NameParser.mentions("Roger Zelazny", in: "Zelazny -- Chronicles of Amber"))
        XCTAssertFalse(NameParser.mentions("Roger Zelazny", in: "Bobiverse"))
    }

    func testAuthorParenSeriesTitleWithYear() {
        let parsed = NameParser.parse("Robin Hobb - (Tawny Man #01) Fool's Errand [Y=2002]")
        XCTAssertEqual(parsed.author, "Robin Hobb")
        XCTAssertEqual(parsed.series, "Tawny Man")
        XCTAssertEqual(parsed.seriesIndex, 1)
        XCTAssertEqual(parsed.title, "Fool's Errand")
        XCTAssertEqual(parsed.year, 2002)
        let novella = NameParser.parse("Robin Hobb - (Realm of the Elderlings #0.5) The Wilful Princess and the Piebald Prince [Y=2013]")
        XCTAssertEqual(novella.seriesIndex, 0.5)
        XCTAssertEqual(novella.title, "The Wilful Princess and the Piebald Prince")
        XCTAssertEqual(novella.year, 2013)
    }

    func testRangeShelfBecomesSubseriesName() {
        XCTAssertEqual(NameParser.cleanSeriesName("(Realm of the Elderlings #7-9) Tawny Man Trilogy"), "Tawny Man")
        XCTAssertEqual(NameParser.seriesRemovingAuthor("Robin Hobb", from: "Robin Hobb - (Realm of the Elderlings #10-13) Rain Wilds Chronicles"), "Rain Wilds Chronicles")
    }

    func testLastCommaFirstAuthors() {
        let parsed = NameParser.parse("Gerber, Michael E. - The E-Myth Revisited - Why Most Small Businesses Don't Work and What to Do About It")
        XCTAssertEqual(parsed.author, "Michael E. Gerber")
        XCTAssertEqual(parsed.title, "The E-Myth Revisited - Why Most Small Businesses Don't Work and What to Do About It")
        XCTAssertEqual(NameParser.normalizePersonName("Austen, Jane"), "Jane Austen")
        XCTAssertEqual(NameParser.normalizePersonName("Jane Austen"), "Jane Austen")
        XCTAssertEqual(NameParser.normalizePersonName("Station Eternity, Book 1"), "Station Eternity, Book 1")
    }

    func testAlbumTagShapes() {
        let ship = NameParser.parse("Ship of Magic: The Liveship Traders, Book One")
        XCTAssertEqual(ship.title, "Ship of Magic")
        XCTAssertEqual(ship.series, "The Liveship Traders")
        XCTAssertEqual(ship.seriesIndex, 1)
        let haven = NameParser.parse("Dragon Haven: Volume Two of the Rain Wilds Chronicles")
        XCTAssertEqual(haven.title, "Dragon Haven")
        XCTAssertEqual(haven.series, "Rain Wilds Chronicles")
        XCTAssertEqual(haven.seriesIndex, 2)
        let keeper = NameParser.parse("Rain Wilds Chronicles #01 - The Dragon Keeper")
        XCTAssertEqual(keeper.title, "The Dragon Keeper")
        XCTAssertEqual(keeper.series, "Rain Wilds Chronicles")
        XCTAssertEqual(keeper.seriesIndex, 1)
        XCTAssertEqual(NameParser.narratorIfNarratedBy("Narrated by Anne Flosnik"), "Anne Flosnik")
        XCTAssertNil(NameParser.narratorIfNarratedBy("Robin Hobb"))
        XCTAssertEqual(BookGrouper.albumClusterKey("The E-Myth Revisited (Unabridged) 6"), BookGrouper.albumClusterKey("E Myth Revisited"))
        XCTAssertEqual(BookGrouper.albumClusterKey("The E-Myth Revisited (Disc 3)"), "e myth revisited")
    }

    func testPersonNameHeuristic() {
        XCTAssertTrue(NameParser.looksLikePersonName("Miguel de Cervantes"))
        XCTAssertTrue(NameParser.looksLikePersonName("James S. A. Corey"))
        XCTAssertFalse(NameParser.looksLikePersonName("The Devils"))
        XCTAssertFalse(NameParser.looksLikePersonName("Crime and Punishment"))
        XCTAssertFalse(NameParser.looksLikePersonName("Life 3.0"))
    }
}
