import XCTest
@testable import Earmark

final class BookGrouperTests: XCTestCase {
    private let sourceID = UUID()

    private func file(_ path: String, title: String? = nil, artist: String? = nil, albumArtist: String? = nil, album: String? = nil, track: Int? = nil, disc: Int? = nil, duration: TimeInterval = 60, chapters: [EmbeddedChapter] = [], hasArtwork: Bool = false) -> ScannedFile {
        var meta = AudioMetadata(duration: duration)
        meta.title = title
        meta.artist = artist
        meta.albumArtist = albumArtist
        meta.album = album
        meta.trackNumber = track
        meta.discNumber = disc
        meta.chapters = chapters
        meta.hasArtwork = hasArtwork
        return ScannedFile(relativePath: path, fileSize: 1000, modifiedAt: nil, metadata: meta)
    }

    private func group(_ files: [ScannedFile], images: [String: [String]] = [:]) -> [Book] {
        BookGrouper.group(BookGrouper.Input(sourceID: sourceID, sourceName: "Test", files: files, imagesByDirectory: images)).map(\.book)
    }

    func testFolderOfChaptersIsOneBookInNaturalOrder() {
        let books = group([
            file("Jane Austen/Pride and Prejudice/10 - Chapter 10.mp3"),
            file("Jane Austen/Pride and Prejudice/2 - Chapter 2.mp3"),
            file("Jane Austen/Pride and Prejudice/1 - Chapter 1.mp3"),
        ])
        XCTAssertEqual(books.count, 1)
        let book = books[0]
        XCTAssertEqual(book.kind, .folder)
        XCTAssertEqual(book.title, "Pride and Prejudice")
        XCTAssertEqual(book.author, "Jane Austen")
        XCTAssertNil(book.series)
        XCTAssertEqual(book.tracks.map(\.fileName), ["1 - Chapter 1.mp3", "2 - Chapter 2.mp3", "10 - Chapter 10.mp3"])
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 10"])
        XCTAssertEqual(book.totalDuration, 180)
    }

    func testTagsWinOverFolderNamesAndTrackNumbersOrder() {
        let books = group([
            file("Stuff/pp_b.mp3", title: "Part Two", artist: "Jane Austen", album: "Pride and Prejudice", track: 2),
            file("Stuff/pp_a.mp3", title: "Part One", artist: "Jane Austen", album: "Pride and Prejudice", track: 1),
        ])
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "Pride and Prejudice")
        XCTAssertEqual(books[0].author, "Jane Austen")
        XCTAssertEqual(books[0].chapters.map(\.title), ["Part One", "Part Two"])
    }

    func testDiscFoldersMergeIntoParentBook() {
        let books = group([
            file("Herman Melville/Moby-Dick/Disc 2/01 The Spouter-Inn.mp3"),
            file("Herman Melville/Moby-Dick/Disc 1/02 The Carpet-Bag.mp3"),
            file("Herman Melville/Moby-Dick/Disc 1/01 Loomings.mp3"),
        ])
        XCTAssertEqual(books.count, 1)
        let book = books[0]
        XCTAssertEqual(book.title, "Moby-Dick")
        XCTAssertEqual(book.author, "Herman Melville")
        XCTAssertEqual(book.relativePath, "Herman Melville/Moby-Dick")
        XCTAssertEqual(book.tracks.map(\.discNumber), [1, 1, 2])
        XCTAssertEqual(book.chapters.map(\.title), ["Loomings", "The Carpet-Bag", "The Spouter-Inn"])
    }

    func testEveryM4BIsItsOwnBookWithEmbeddedChapters() {
        let chapters = [EmbeddedChapter(title: "Letter 1", start: 0, duration: 30), EmbeddedChapter(title: "Letter 2", start: 30, duration: 30)]
        let books = group([
            file("Mary Shelley/Frankenstein.m4b", title: "Frankenstein", artist: "Mary Shelley", duration: 60, chapters: chapters),
            file("Mary Shelley/The Last Man.m4b", title: "The Last Man", artist: "Mary Shelley", duration: 60),
        ])
        XCTAssertEqual(books.count, 2)
        let frankenstein = books.first { $0.title == "Frankenstein" }!
        XCTAssertEqual(frankenstein.kind, .singleFile)
        XCTAssertEqual(frankenstein.author, "Mary Shelley")
        XCTAssertEqual(frankenstein.chapters.map(\.title), ["Letter 1", "Letter 2"])
        XCTAssertEqual(frankenstein.chapters[1].start, 30)
        let lastMan = books.first { $0.title == "The Last Man" }!
        XCTAssertEqual(lastMan.chapters.count, 1)
        XCTAssertEqual(lastMan.chapters[0].title, "The Last Man")
    }

    func testLooseFilesWithDifferentAlbumsSplitIntoBooks() {
        let books = group([
            file("Loose/raven.mp3", title: "The Raven", artist: "Edgar Allan Poe", album: "The Raven"),
            file("Loose/ozy.mp3", title: "Ozymandias", artist: "Percy Bysshe Shelley", album: "Ozymandias"),
        ])
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(Set(books.map(\.title)), ["The Raven", "Ozymandias"])
        XCTAssertEqual(books.first { $0.title == "The Raven" }?.author, "Edgar Allan Poe")
        XCTAssertTrue(books.allSatisfy { $0.kind == .singleFile })
    }

    func testAuthorSeriesBookConventionAndSeriesIndex() {
        let books = group([
            file("Audiobooks/Lewis Carroll/Alice/1 - Alice's Adventures in Wonderland/01.mp3"),
            file("Audiobooks/Lewis Carroll/Alice/1 - Alice's Adventures in Wonderland/02.mp3"),
            file("Audiobooks/Lewis Carroll/Alice/2 - Through the Looking-Glass/01.mp3"),
            file("Audiobooks/Lewis Carroll/Alice/2 - Through the Looking-Glass/02.mp3"),
        ])
        XCTAssertEqual(books.count, 2)
        let alice = books.first { $0.title == "Alice's Adventures in Wonderland" }
        XCTAssertNotNil(alice)
        XCTAssertEqual(alice?.author, "Lewis Carroll")
        XCTAssertEqual(alice?.series, "Alice")
        XCTAssertEqual(alice?.seriesIndex, 1)
        XCTAssertEqual(alice?.chapters.map(\.title), ["Chapter 1", "Chapter 2"])
        let glass = books.first { $0.title == "Through the Looking-Glass" }
        XCTAssertEqual(glass?.seriesIndex, 2)
    }

    func testSingleFileInsideItsOwnFolderUsesFolderAsTitle() {
        let books = group([file("Frank Herbert/Dune/dune_full.mp3", duration: 3600)])
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "Dune")
        XCTAssertEqual(books[0].author, "Frank Herbert")
        XCTAssertNil(books[0].series)
    }

    func testSingleFileInsideAuthorFolderUsesFileNameAsTitle() {
        let books = group([file("Mary Shelley/Frankenstein.mp3", duration: 3600)])
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "Frankenstein")
        XCTAssertEqual(books[0].author, "Mary Shelley")
        XCTAssertNil(books[0].series)
    }

    func testSingleFileNamedWithAuthorStripsTheAuthor() {
        let books = group([file("Frank Herbert/Dune - Frank Herbert.mp3", duration: 3600)])
        XCTAssertEqual(books[0].title, "Dune")
        XCTAssertEqual(books[0].author, "Frank Herbert")
        XCTAssertEqual(BookGrouper.titleRemovingFolderName(from: "Frank Herbert - Dune (Unabridged)", folderName: "Frank Herbert"), "Dune (Unabridged)")
    }

    func testTaggedSingleFileMatchingFolderTreatsFolderAsBook() {
        let books = group([file("Frank Herbert/Dune/audiobook.mp3", title: "Dune", artist: "Frank Herbert", album: "Dune")])
        XCTAssertEqual(books[0].title, "Dune")
        XCTAssertEqual(books[0].author, "Frank Herbert")
        XCTAssertNil(books[0].series, "the book's own folder must not be mistaken for a series")
    }

    // MARK: Real BookPlayer library shapes

    func testStandaloneM4BWithSeriesInFileName() {
        let books = group([file("Processed/James S. A. Corey - Captive's War, Book 2 - The Faith of Beasts.m4b", duration: 3600)])
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "The Faith of Beasts")
        XCTAssertEqual(books[0].author, "James S. A. Corey")
        XCTAssertEqual(books[0].series, "Captive's War")
        XCTAssertEqual(books[0].seriesIndex, 2)
    }

    func testSeriesShelfWithBitrateJunkAndTaggedArtist() {
        let shelf = "Zelazny -- Chronicles of Amber -- 48kbps unabr"
        let books = group([
            file("\(shelf)/Roger Zelazny - Amber 01 - Nine Princes in Amber (48 KBps Unabridged)/01.mp3", artist: "Roger Zelazny", album: "Nine Princes in Amber"),
            file("\(shelf)/Roger Zelazny - Amber 01 - Nine Princes in Amber (48 KBps Unabridged)/02.mp3", artist: "Roger Zelazny", album: "Nine Princes in Amber"),
            file("\(shelf)/Roger Zelazny - Amber 02 - Guns of Avalon (48 KBps Unabridged)/01.mp3", artist: "Roger Zelazny", album: "Guns of Avalon"),
            file("\(shelf)/Roger Zelazny - Amber 02 - Guns of Avalon (48 KBps Unabridged)/02.mp3", artist: "Roger Zelazny", album: "Guns of Avalon"),
        ])
        XCTAssertEqual(books.count, 2)
        let first = books.first { $0.title == "Nine Princes in Amber" }
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.author, "Roger Zelazny")
        XCTAssertEqual(first?.series, "Amber")
        XCTAssertEqual(first?.seriesIndex, 1)
        XCTAssertEqual(books.first { $0.title == "Guns of Avalon" }?.seriesIndex, 2)
    }

    func testSeriesShelfNamedAfterAuthorAndSeries() {
        let books = group([
            file("James S. A. Corey - The Expanse Series/Leviathan Wakes/01.mp3", artist: "James S. A. Corey", album: "Leviathan Wakes"),
            file("James S. A. Corey - The Expanse Series/Leviathan Wakes/02.mp3", artist: "James S. A. Corey", album: "Leviathan Wakes"),
        ])
        XCTAssertEqual(books[0].title, "Leviathan Wakes")
        XCTAssertEqual(books[0].author, "James S. A. Corey")
        XCTAssertEqual(books[0].series, "The Expanse")
    }

    func testUntaggedSeriesShelfIsNotMistakenForAuthor() {
        let books = group([
            file("Bobiverse/We Are Legion/01.mp3", artist: "Dennis E. Taylor"),
            file("Bobiverse/We Are Legion/02.mp3", artist: "Dennis E. Taylor"),
        ])
        XCTAssertEqual(books[0].author, "Dennis E. Taylor")
        XCTAssertEqual(books[0].series, "Bobiverse")
        XCTAssertEqual(books[0].title, "We Are Legion")
    }

    func testNarratorAndTitleFromReadByFolder() {
        let files = (1...3).flatMap { disc in
            (1...2).map { track in file(String(format: "Don Quixote - read by George Guidall/CD%02d-%02d - Miguel de Cervantes - Don Quixote.mp3", disc, track)) }
        }
        let books = group(files)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "Don Quixote")
        XCTAssertEqual(books[0].narrator, "George Guidall")
        XCTAssertEqual(books[0].chapters.first?.title, "Disc 1 · Track 1")
        XCTAssertEqual(books[0].chapters.last?.title, "Disc 3 · Track 2")
    }

    func testChapterTitlesLoseTheRepeatedBookName() {
        let files = (1...12).map { file(String(format: "Crime and Punishment/Crime and Punishment NA %02d.mp3", $0)) }
        let books = group(files)
        XCTAssertEqual(books[0].title, "Crime and Punishment")
        XCTAssertEqual(books[0].chapters.map(\.title).prefix(3), ["Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(books[0].chapters.last?.title, "Chapter 12")
    }

    func testRomanNumeralChapterNamesSurvive() {
        let books = group([
            file("Morals and Dogma - Albert Pike/01 - I. Preface - Apprentice.mp3"),
            file("Morals and Dogma - Albert Pike/02 - II. The Fellow-Craft (Part 1).mp3"),
            file("Morals and Dogma - Albert Pike/48 - XXIII. Chief of the Tabernacle.mp3"),
        ])
        XCTAssertEqual(books[0].title, "Morals and Dogma")
        XCTAssertEqual(books[0].author, "Albert Pike")
        XCTAssertEqual(books[0].chapters.map(\.title), ["I. Preface - Apprentice", "II. The Fellow-Craft (Part 1)", "XXIII. Chief of the Tabernacle"])
    }

    func testProcessedFolderIsInvisible() {
        let books = group([file("Processed/Jeff Vandermeer/Annihilation/01.mp3"), file("Processed/Jeff Vandermeer/Annihilation/02.mp3")])
        XCTAssertEqual(books[0].author, "Jeff Vandermeer")
        XCTAssertEqual(books[0].title, "Annihilation")
        XCTAssertNil(books[0].series)
    }

    func testTitledDiscFoldersMergeAndGetPositionalChapterNames() {
        let shelf = "Gerber, Michael E. - The E-Myth Revisited - Why Most Small Businesses Don't Work and What to Do About It"
        let books = group([
            file("\(shelf)/The E-Myth Revisited (Disc 1)/1-01 1a.mp3"),
            file("\(shelf)/The E-Myth Revisited (Disc 1)/1-02 1b.mp3"),
            file("\(shelf)/The E-Myth Revisited (Disc 2)/2-01 2a.mp3"),
        ])
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].author, "Michael E. Gerber")
        XCTAssertTrue(books[0].title.hasPrefix("The E-Myth Revisited"))
        XCTAssertEqual(books[0].tracks.map(\.discNumber), [1, 1, 2])
        XCTAssertEqual(books[0].chapters.map(\.title), ["Disc 1 · Track 1", "Disc 1 · Track 2", "Disc 2 · Track 1"])
    }

    func testNestedSeriesShelvesFromNAS() {
        let books = group([
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #7-9) Tawny Man Trilogy/Robin Hobb - (Tawny Man #01) Fool's Errand [Y=2002]/Fool's Errand 01.mp3"),
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #7-9) Tawny Man Trilogy/Robin Hobb - (Tawny Man #01) Fool's Errand [Y=2002]/Fool's Errand 02.mp3"),
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #7-9) Tawny Man Trilogy/Robin Hobb - (Tawny Man #01) Fool's Errand [Y=2002]/Fool's Errand 03.mp3"),
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #0.5) The Wilful Princess and the Piebald Prince [Y=2013]/The Wilful Princess and the Piebald Prince (Unabridged).m4b"),
        ])
        XCTAssertEqual(books.count, 2)
        let errand = books.first { $0.title == "Fool's Errand" }
        XCTAssertNotNil(errand)
        XCTAssertEqual(errand?.author, "Robin Hobb")
        XCTAssertEqual(errand?.series, "Tawny Man")
        XCTAssertEqual(errand?.seriesIndex, 1)
        XCTAssertEqual(errand?.year, 2002)
        XCTAssertEqual(errand?.chapters.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 3"])
        let princess = books.first { $0.title == "The Wilful Princess and the Piebald Prince" }
        XCTAssertEqual(princess?.series, "Realm of the Elderlings")
        XCTAssertEqual(princess?.seriesIndex, 0.5)
        XCTAssertEqual(princess?.author, "Robin Hobb")
    }

    // MARK: Real NAS results (first scan of smb://NAS/all/downloads/books)

    func testDiscFoldersStayOneBookDespiteDriftingAlbumTags() {
        let shelf = "Gerber, Michael E. - The E-Myth Revisited - Why Most Small Businesses Don't Work and What to Do About It"
        let books = group([
            file("\(shelf)/The E-Myth Revisited (Disc 1)/1-01 1a.mp3", artist: "Michael E. Gerber", album: "E Myth Revisited", track: 1),
            file("\(shelf)/The E-Myth Revisited (Disc 3)/3-01 3a.mp3", artist: "Michael E. Gerber", album: "The E-Myth Revisited (Disc 3)", track: 1),
            file("\(shelf)/The E-Myth Revisited (Disc 6)/6-01 6a.mp3", artist: "Michael E. Gerber", album: "The E-Myth Revisited (Unabridged) 6", track: 1),
            file("\(shelf)/The E-Myth Revisited (Disc 7)/7-01 7a.mp3", artist: "Michael E. Gerber", album: "The E-Myth Revisited (Unabridged) 7", track: 1),
        ])
        XCTAssertEqual(books.count, 1, "seven disc folders are one book even when their album tags drift")
        XCTAssertTrue(books[0].title.hasPrefix("The E-Myth Revisited"), books[0].title)
        XCTAssertEqual(books[0].author, "Michael E. Gerber")
        XCTAssertEqual(books[0].tracks.map(\.discNumber), [1, 3, 6, 7])
    }

    func testNarratedByArtistTagBecomesNarrator() {
        let books = group([
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #4-6) Liveship Traders/Robin Hobb - (Liveship Traders #01) Ship of Magic [Y=1998]/01.mp3", artist: "Narrated by Anne Flosnik", album: "Ship of Magic: The Liveship Traders, Book One"),
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #4-6) Liveship Traders/Robin Hobb - (Liveship Traders #01) Ship of Magic [Y=1998]/02.mp3", artist: "Narrated by Anne Flosnik", album: "Ship of Magic: The Liveship Traders, Book One"),
        ])
        XCTAssertEqual(books[0].title, "Ship of Magic")
        XCTAssertEqual(books[0].author, "Robin Hobb")
        XCTAssertEqual(books[0].narrator, "Anne Flosnik")
        XCTAssertEqual(books[0].series, "Liveship Traders")
        XCTAssertEqual(books[0].seriesIndex, 1)
        XCTAssertEqual(books[0].year, 1998)
    }

    func testStructuredFolderBeatsSloppyAlbumTagAndNarratorInArtist() {
        let books = group([
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #10-13) Rain Wilds Chronicles/Robin Hobb - (Rain Wilds Chronicles #01) The Dragon Keeper [Y=2009]/01.mp3", artist: "Saskia Butler", album: "Rain Wilds Chronicles #01 - The Dragon Keeper"),
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #10-13) Rain Wilds Chronicles/Robin Hobb - (Rain Wilds Chronicles #01) The Dragon Keeper [Y=2009]/02.mp3", artist: "Saskia Butler", album: "Rain Wilds Chronicles #01 - The Dragon Keeper"),
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #1-3) Farseer trilogy/Robin Hobb - (Farseer Trilogy #01) Assassin's Apprentice [Y=1995]/01.mp3", artist: "Robin Hobb", album: "F1- Assassin's Apprentice"),
            file("Robin Hobb/Robin Hobb - (Realm of the Elderlings #1-3) Farseer trilogy/Robin Hobb - (Farseer Trilogy #01) Assassin's Apprentice [Y=1995]/02.mp3", artist: "Robin Hobb", album: "F1- Assassin's Apprentice"),
        ])
        XCTAssertEqual(books.count, 2)
        let keeper = books.first { $0.title == "The Dragon Keeper" }
        XCTAssertNotNil(keeper, books.map(\.title).description)
        XCTAssertEqual(keeper?.author, "Robin Hobb", "the shelf confirms the folder's author; the artist tag was the narrator")
        XCTAssertEqual(keeper?.narrator, "Saskia Butler")
        XCTAssertEqual(keeper?.series, "Rain Wilds Chronicles")
        XCTAssertEqual(keeper?.seriesIndex, 1)
        let apprentice = books.first { $0.title == "Assassin's Apprentice" }
        XCTAssertNotNil(apprentice, "'F1- Assassin's Apprentice' album tag must not win over the folder name")
        XCTAssertEqual(apprentice?.series, "Farseer")
        XCTAssertEqual(apprentice?.seriesIndex, 1)
    }

    func testAuthorCasingIsCanonicalised() {
        var books = group([
            file("A/Book One/01.mp3", artist: "Robin Hobb"), file("A/Book One/02.mp3", artist: "Robin Hobb"),
            file("A/Book Two/01.mp3", artist: "Robin hobb"), file("A/Book Two/02.mp3", artist: "Robin hobb"),
            file("A/Book Three/01.mp3", artist: "Robin Hobb"), file("A/Book Three/02.mp3", artist: "Robin Hobb"),
        ])
        XCTAssertEqual(Set(books.map(\.author)), ["Robin Hobb"])
        books[0].author = "robin hobb"
        BookGrouper.canonicalizeAuthors(&books)
        XCTAssertEqual(Set(books.map(\.author)), ["Robin Hobb"])
    }

    func testMusicTemplateComposerIsNotANarratorAndJunkIsStrippedFromTagTitles() {
        var meta = AudioMetadata(duration: 10)
        meta.title = "The Inheritance (Unabridged)"; meta.album = "The Inheritance (Unabridged)"; meta.artist = "Robin Hobb"; meta.composer = "John Lennon/Paul McCartney"
        let single = ScannedFile(relativePath: "Robin Hobb/Robin Hobb - (Realm of the Elderlings #1.5) The Inheritance [Y=2000]/The Inheritance (Unabridged).m4b", fileSize: 10, modifiedAt: nil, metadata: meta)
        let books = group([single])
        XCTAssertEqual(books[0].title, "The Inheritance")
        XCTAssertNil(books[0].narrator)
        XCTAssertEqual(books[0].seriesIndex, 1.5)
        XCTAssertEqual(books[0].year, 2000)
    }

    func testStableIDsAcrossRuns() {
        let files = [file("A/B/01.mp3"), file("A/B/02.mp3")]
        let first = group(files)
        let second = group(files.reversed())
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertTrue(first[0].id.hasPrefix(sourceID.uuidString))
    }

    func testArtworkCandidatesPreferCoverImageNames() {
        let drafts = BookGrouper.group(BookGrouper.Input(
            sourceID: sourceID,
            sourceName: "Test",
            files: [file("Book/01.mp3"), file("Book/02.mp3", hasArtwork: true)],
            imagesByDirectory: ["Book": ["Book/scan.jpg", "Book/cover.jpg"]]
        ))
        XCTAssertEqual(drafts.count, 1)
        let candidates = drafts[0].artworkCandidates
        XCTAssertEqual(candidates.first, ArtworkCandidate(kind: .embedded, relativePath: "Book/02.mp3"))
        XCTAssertEqual(candidates.dropFirst().first, ArtworkCandidate(kind: .imageFile, relativePath: "Book/cover.jpg"))
    }

    func testChapterTitleCleaning() {
        let bookTitle = "Pride and Prejudice"
        XCTAssertEqual(BookGrouper.chapterTitle(for: file("x/Pride and Prejudice - 01 - Chapter 1.mp3"), index: 0, bookTitle: bookTitle), "Chapter 1")
        XCTAssertEqual(BookGrouper.chapterTitle(for: file("x/07.mp3"), index: 6, bookTitle: bookTitle), "Chapter 7")
        XCTAssertEqual(BookGrouper.chapterTitle(for: file("x/03_The_Spouter_Inn.mp3"), index: 2, bookTitle: bookTitle), "The Spouter Inn")
        XCTAssertEqual(BookGrouper.chapterTitle(for: file("x/track.mp3", title: "Prologue"), index: 0, bookTitle: bookTitle), "Prologue")
    }

    func testDiscFolderDetection() {
        XCTAssertEqual(BookGrouper.discNumber(fromFolderName: "Disc 1"), 1)
        XCTAssertEqual(BookGrouper.discNumber(fromFolderName: "CD02"), 2)
        XCTAssertEqual(BookGrouper.discNumber(fromFolderName: "Part_3"), 3)
        XCTAssertNil(BookGrouper.discNumber(fromFolderName: "Discworld"))
        XCTAssertNil(BookGrouper.discNumber(fromFolderName: "Part Two"))
    }

    func testSeriesIndexParsing() {
        XCTAssertEqual(BookGrouper.parseSeriesIndex(from: "3 - The Title").0, 3)
        XCTAssertEqual(BookGrouper.parseSeriesIndex(from: "3 - The Title").1, "The Title")
        XCTAssertEqual(BookGrouper.parseSeriesIndex(from: "Book 2 - Deeper").0, 2)
        XCTAssertNil(BookGrouper.parseSeriesIndex(from: "1984").0)
        XCTAssertEqual(BookGrouper.parseSeriesIndex(from: "1984").1, "1984")
        XCTAssertNil(BookGrouper.parseSeriesIndex(from: "2001: A Space Odyssey").0)
    }
}
