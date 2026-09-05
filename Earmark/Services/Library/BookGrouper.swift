import Foundation

/// A playable file found while walking a source, plus whatever tags we could read.
struct ScannedFile: Hashable, Sendable {
    var relativePath: String
    var fileSize: Int64
    var modifiedAt: Date?
    var metadata: AudioMetadata?
    var needsDownload = false
    var containerHint: String?

    var fileName: String { (relativePath as NSString).lastPathComponent }
    /// Directory relative to the source root; "" for files sitting at the root.
    var directory: String { (relativePath as NSString).deletingLastPathComponent }
    var stem: String { (fileName as NSString).deletingPathExtension }
    var ext: String { (fileName as NSString).pathExtension.lowercased() }
}

struct ArtworkCandidate: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case embedded, imageFile }
    var kind: Kind
    var relativePath: String
}

struct BookDraft: Sendable {
    var book: Book
    var artworkCandidates: [ArtworkCandidate]
}

/// Pure logic that turns a flat list of files into books. No I/O, fully unit-testable.
///
/// Rules, in order:
/// 1. `Disc N` / `CD N` / `Part N` folders merge into their parent.
/// 2. Every `.m4b` is its own book.
/// 3. A folder with one remaining file is a single-file book.
/// 4. A folder whose files carry two or more distinct album tags is split by album.
/// 5. Otherwise the folder is one book; files are its chapters.
/// Author/series come from tags first, then the `Author/Series/Book` folder convention.
enum BookGrouper {
    struct Input: Sendable {
        var sourceID: UUID
        var sourceName: String
        var files: [ScannedFile]
        /// Image files found during the walk, keyed by directory relative path.
        var imagesByDirectory: [String: [String]] = [:]
        var now: Date = .now
    }

    static let genericFolderNames: Set<String> = [
        "audiobooks", "audiobook", "books", "book", "audio", "music", "downloads", "download",
        "library", "media", "documents", "files", "on my iphone", "icloud drive", "earmark", "unknown", "various",
        // Other apps' import folders (BookPlayer keeps everything under Documents/Processed).
        "processed", "inbox", "bookplayer", "imports", "import", "new", "misc", "other", "unsorted", "to sort",
        "loose", "singles", "single", "random", "assorted", "standalone", "standalones", "one offs", "oneoffs", "various authors", "va", "temp", "tmp",
        // Genre shelves are neither authors nor series.
        "fiction", "non fiction", "nonfiction", "sci fi", "scifi", "science fiction", "fantasy", "classics", "classic",
        "history", "business", "self help", "kids", "children", "romance", "mystery", "thriller", "horror", "biography",
        "science", "philosophy", "religion", "comedy", "poetry", "drama", "nonfic", "lit", "literature",
    ]

    // MARK: - Entry point

    static func group(_ input: Input) -> [BookDraft] {
        var filesByRoot: [String: [ScannedFile]] = [:]
        var discByFile: [String: Int] = [:]

        var byDirectory: [String: [ScannedFile]] = [:]
        for file in input.files {
            byDirectory[file.directory, default: []].append(file)
        }
        for (directory, files) in byDirectory {
            var root = directory
            if let disc = discNumber(fromFolderName: (directory as NSString).lastPathComponent), !directory.isEmpty {
                root = (directory as NSString).deletingLastPathComponent
                for file in files { discByFile[file.relativePath] = disc }
            }
            filesByRoot[root, default: []].append(contentsOf: files)
        }

        var drafts: [BookDraft] = []
        for (root, files) in filesByRoot.sorted(by: { $0.key.naturallyPrecedes($1.key) }) {
            let m4bs = files.filter { $0.ext == "m4b" }
            let rest = files.filter { $0.ext != "m4b" }
            // An .m4b is usually one standalone book — but a folder can hold a multi-part m4b book
            // (dozens of "NNN - Title.m4b", or "Title 1/2/3.m4b"). Parts that share a book key are one
            // book; files with distinct keys stay separate books.
            var m4bByKey: [String: [ScannedFile]] = [:]
            for file in m4bs { m4bByKey[bookPartKey(file.stem), default: []].append(file) }
            for (key, groupFiles) in m4bByKey.sorted(by: { $0.key.naturallyPrecedes($1.key) }) {
                if groupFiles.count == 1 {
                    drafts.append(makeSingleFileBook(groupFiles[0], root: root, siblingCount: files.count, groupKey: groupFiles[0].fileName, input: input))
                } else {
                    drafts.append(makeFolderBook(groupFiles, root: root, groupKey: key, titleOverride: nonGeneric(groupFiles[0].metadata?.album), discByFile: discByFile, input: input))
                }
            }
            guard !rest.isEmpty else { continue }
            if rest.count == 1 {
                drafts.append(makeSingleFileBook(rest[0], root: root, siblingCount: files.count, groupKey: "", input: input))
                continue
            }

            let discMerged = rest.contains { discByFile[$0.relativePath] != nil }
            let albumGroups = albumClusters(rest)
            let named = albumGroups.filter { !$0.key.isEmpty }
            if named.count >= 2, !discMerged {
                for (key, groupFiles) in named.sorted(by: { $0.key < $1.key }) {
                    if groupFiles.count == 1 {
                        drafts.append(makeSingleFileBook(groupFiles[0], root: root, siblingCount: files.count, groupKey: key, input: input))
                    } else {
                        drafts.append(makeFolderBook(groupFiles, root: root, groupKey: key, titleOverride: groupFiles[0].metadata?.album, discByFile: discByFile, input: input))
                    }
                }
                if let untagged = albumGroups[""], !untagged.isEmpty {
                    if untagged.count == 1 {
                        drafts.append(makeSingleFileBook(untagged[0], root: root, siblingCount: files.count, groupKey: "untagged", input: input))
                    } else {
                        drafts.append(makeFolderBook(untagged, root: root, groupKey: "untagged", titleOverride: nil, discByFile: discByFile, input: input))
                    }
                }
            } else {
                drafts.append(makeFolderBook(rest, root: root, groupKey: "", titleOverride: nil, discByFile: discByFile, input: input))
            }
        }
        var books = drafts.map(\.book)
        canonicalizeAuthors(&books)
        for index in drafts.indices { drafts[index].book = books[index] }
        return drafts.sorted { $0.book.title.naturallyPrecedes($1.book.title) }
    }

    /// A key equal for numbered parts of the same book ("021 - Best Served Cold",
    /// "The Blade Itself 1/2/3") and different for distinct titles. Only used to decide whether
    /// several .m4b files in one folder are one multi-part book or separate books.
    static func bookPartKey(_ stem: String) -> String {
        var s = stem
        s = s.replacingOccurrences(of: #"^\s*\d{1,4}\s*[-._)\]]\s*"#, with: "", options: .regularExpression)          // leading track no.
        s = s.replacingOccurrences(of: #"(?i)[\s\-_]+(?:part|pt|disc|cd|vol|volume|book|bk|section|sec)?\.?\s*\d{1,4}\s*$"#, with: "", options: .regularExpression) // trailing part no.
        s = s.replacingOccurrences(of: #"(?i)\s*\((?:un)?abridged\)|\s*\(booktrack\)"#, with: "", options: .regularExpression) // decorations
        let key = s.normalizedForMatching
        return key.isEmpty ? stem.normalizedForMatching : key
    }

    /// Groups files whose album tags mean the same book: "The E-Myth Revisited (Disc 3)",
    /// "E Myth Revisited", "The E-Myth Revisited (Unabridged) 6" all land in one cluster.
    static func albumClusters(_ files: [ScannedFile]) -> [String: [ScannedFile]] {
        var byKey: [String: [ScannedFile]] = [:]
        for file in files {
            byKey[albumClusterKey(file.metadata?.album), default: []].append(file)
        }
        // Merge keys that contain one another ("e myth revisited" ⊂ "e myth revisited why most…").
        let keys = byKey.keys.filter { !$0.isEmpty }.sorted { $0.count < $1.count }
        var merged: [String: [ScannedFile]] = [:]
        var representative: [String: String] = [:]
        for key in keys {
            if let existing = merged.keys.first(where: { key.contains($0) || $0.contains(key) }) {
                merged[existing, default: []] += byKey[key] ?? []
                representative[key] = existing
            } else {
                merged[key] = byKey[key]
                representative[key] = key
            }
        }
        if let untagged = byKey[""] { merged[""] = untagged }
        return merged
    }

    static func albumClusterKey(_ album: String?) -> String {
        guard let album = nonGeneric(album) else { return "" }
        var text = NameParser.clean(album)
        text = text.replacingOccurrences(of: #"[\s(\[-]*(?:cd|disc|disk|part|pt|vol(?:ume)?)\s*\d+[)\]]?"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
        var key = text.normalizedForMatching
        if key.hasPrefix("the ") { key.removeFirst(4) }
        return key
    }

    /// "Robin hobb" and "Robin Hobb" are one person; use the most common spelling everywhere.
    /// Removes a trailing parenthetical an audiobook tag sometimes appends to the author — a series
    /// or "world" name, "(Unabridged)", "(Booktrack)" — that otherwise splits one author into several.
    static func cleanAuthor(_ author: String) -> String {
        var text = author
        // "Bobiverse, Book 4 by Dennis E. Taylor" → keep the person after the last " by ".
        if let byRange = text.range(of: " by ", options: [.caseInsensitive, .backwards]) {
            let tail = String(text[byRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if NameParser.looksLikePersonName(tail) { text = tail }
        }
        let stripped = text.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? author : stripped
    }

    static func canonicalizeAuthors(_ books: inout [Book]) {
        // Strip tag cruft like "Joe Abercrombie (First Law World)" so variants collapse to one author.
        for index in books.indices {
            if let author = books[index].author { books[index].author = cleanAuthor(author) }
        }
        var spellings: [String: [String: Int]] = [:]
        for book in books {
            guard let author = book.author else { continue }
            spellings[author.normalizedForMatching, default: [:]][author, default: 0] += 1
        }
        let canonical = spellings.compactMapValues { counts -> String? in
            counts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.filter(\.isUppercase).count < rhs.key.filter(\.isUppercase).count
            }?.key
        }
        for index in books.indices {
            if let author = books[index].author, let best = canonical[author.normalizedForMatching] {
                books[index].author = best
            }
        }
    }

    /// Composer tags left over from music templates ("John Lennon/Paul McCartney") aren't narrators.
    static func validNarrator(_ candidate: String?, author: String?) -> String? {
        guard let candidate = nonGeneric(candidate) else { return nil }
        if candidate.contains("/") || candidate.contains(";") || candidate.contains(",") { return nil }
        if let author, namesMatch(candidate, author) { return nil }
        return NameParser.narratorIfNarratedBy(candidate) ?? candidate
    }

    // MARK: - Builders

    private static func makeFolderBook(_ files: [ScannedFile], root: String, groupKey: String, titleOverride: String?, discByFile: [String: Int], input: Input) -> BookDraft {
        let ordered = orderedTracks(files, discByFile: discByFile)
        let rootName = (root as NSString).lastPathComponent
        let folderName = root.isEmpty ? input.sourceName : rootName
        let rawTagAuthor = mostCommon(ordered.compactMap { nonGeneric($0.metadata?.albumArtist) })
            ?? mostCommon(ordered.compactMap { nonGeneric($0.metadata?.artist) })
        let tagAuthor = rawTagAuthor.flatMap { NameParser.narratorIfNarratedBy($0) == nil ? $0 : nil }
        let parsedFolder = NameParser.parse(folderName, knownAuthor: tagAuthor)
        // A folder named "Author - (Series #N) Title" was organised on purpose; trust it over album tags.
        let structuredFolder = !root.isEmpty && (parsedFolder.series != nil || parsedFolder.seriesIndex != nil)
        let albums = ordered.compactMap { nonGeneric($0.metadata?.album) }.map { NameParser.clean($0) }
        let distinctAlbums = Set(albums.map(\.normalizedForMatching))
        let parsedAlbum: NameParser.Parsed? = distinctAlbums.count == 1 ? albums.first.map { NameParser.parse($0, knownAuthor: tagAuthor) } : nil

        let rawTitle: String
        if let titleOverride {
            rawTitle = NameParser.parse(titleOverride, knownAuthor: tagAuthor).title
        } else if structuredFolder {
            rawTitle = parsedFolder.title
        } else if let parsedAlbum {
            rawTitle = parsedAlbum.title
        } else if distinctAlbums.count > 1, !root.isEmpty {
            rawTitle = parsedFolder.title // tags disagree with each other; the folder is the tiebreaker
        } else {
            rawTitle = mostCommon(albums).map { NameParser.parse($0).title } ?? parsedFolder.title
        }
        let (leadingIndex, title) = parseSeriesIndex(from: rawTitle)

        let parsedName = parsedFolder.filling(from: parsedAlbum ?? NameParser.Parsed(title: rawTitle))
        let naming = resolveNaming(bookDirectory: root, isBookFolder: true, tagAuthor: rawTagAuthor, parsedName: parsedName)
        let author = naming.author
        let series = naming.series
        let seriesIndex = leadingIndex ?? naming.seriesIndex
        let narrator = validNarrator(mostCommon(ordered.compactMap { nonGeneric($0.metadata?.composer) }), author: author) ?? naming.narrator ?? parsedName.narrator

        let tracks = ordered.map { file in
            Track(
                relativePath: file.relativePath,
                fileName: file.fileName,
                title: file.metadata?.title,
                duration: file.metadata?.duration ?? 0,
                fileSize: file.fileSize,
                modifiedAt: file.modifiedAt,
                trackNumber: file.metadata?.trackNumber,
                discNumber: discByFile[file.relativePath] ?? file.metadata?.discNumber,
                needsDownload: file.needsDownload,
                containerHint: file.containerHint
            )
        }
        let chapters = buildChapters(files: ordered, tracks: tracks, bookTitle: title, author: author)

        var artwork: [ArtworkCandidate] = []
        if let embedded = ordered.first(where: { $0.metadata?.hasArtwork == true }) {
            artwork.append(ArtworkCandidate(kind: .embedded, relativePath: embedded.relativePath))
        }
        artwork += rankedImages(in: root, preferStem: nil, input: input).map { ArtworkCandidate(kind: .imageFile, relativePath: $0) }
        for discDir in Set(ordered.map(\.directory)).sorted() where discDir != root {
            artwork += rankedImages(in: discDir, preferStem: nil, input: input).map { ArtworkCandidate(kind: .imageFile, relativePath: $0) }
        }

        let book = Book(
            id: Book.makeID(sourceID: input.sourceID, relativePath: root, groupKey: groupKey),
            sourceID: input.sourceID,
            relativePath: root,
            kind: .folder,
            title: title,
            author: author,
            series: series,
            seriesIndex: seriesIndex,
            narrator: narrator == author ? nil : narrator,
            year: mostCommonInt(ordered.compactMap { $0.metadata?.year }) ?? parsedFolder.year,
            tracks: tracks,
            chapters: chapters,
            artworkID: nil,
            addedAt: input.now,
            totalBytes: tracks.reduce(0) { $0 + $1.fileSize }
        )
        return BookDraft(book: book, artworkCandidates: artwork)
    }

    private static func makeSingleFileBook(_ file: ScannedFile, root: String, siblingCount: Int, groupKey: String, input: Input) -> BookDraft {
        let rootName = (root as NSString).lastPathComponent
        let folderEligible = siblingCount == 1 && !root.isEmpty && !isGeneric(rootName)
        let meta = file.metadata
        let rawTagAuthor = nonGeneric(meta?.albumArtist) ?? nonGeneric(meta?.artist)
        let tagAuthor = rawTagAuthor.flatMap { NameParser.narratorIfNarratedBy($0) == nil ? $0 : nil }
        let parsedStem = NameParser.parse(file.stem, knownAuthor: tagAuthor)
        let parsedFolder = folderEligible ? NameParser.parse(rootName, knownAuthor: tagAuthor) : nil
        let structuredFolder = parsedFolder.map { $0.series != nil || $0.seriesIndex != nil } ?? false
        let parsedTag = (nonGeneric(meta?.album) ?? nonGeneric(meta?.title)).map { NameParser.parse(NameParser.clean($0), knownAuthor: tagAuthor) }

        let rawTitle: String
        let isBookFolder: Bool
        if structuredFolder, let parsedFolder {
            rawTitle = parsedFolder.title
            isBookFolder = true
        } else if let parsedTag {
            rawTitle = parsedTag.title
            isBookFolder = folderEligible && (namesMatch(rootName, parsedTag.title) || (parsedFolder.map { namesMatch($0.title, parsedTag.title) } ?? false))
        } else if let parsedFolder {
            // Compare the file's own words against the folder's *title* (author/series/year stripped).
            let (_, folderIsBook) = singleFileTitle(stem: parsedStem.title, folderName: parsedFolder.title)
            isBookFolder = folderIsBook
            rawTitle = folderIsBook ? parsedFolder.title : titleRemovingFolderName(from: parsedStem.title, folderName: rootName)
        } else {
            rawTitle = titleRemovingFolderName(from: parsedStem.title, folderName: rootName)
            isBookFolder = false
        }
        let (leadingIndex, title) = parseSeriesIndex(from: rawTitle)

        let base = (isBookFolder ? parsedFolder : nil) ?? parsedStem
        let parsedName = base.filling(from: parsedTag ?? parsedStem).filling(from: parsedStem)
        let naming = resolveNaming(bookDirectory: root, isBookFolder: isBookFolder, tagAuthor: rawTagAuthor, parsedName: parsedName)
        let author = naming.author
        let series = naming.series
        let seriesIndex = leadingIndex ?? naming.seriesIndex

        let track = Track(
            relativePath: file.relativePath,
            fileName: file.fileName,
            title: meta?.title,
            duration: meta?.duration ?? 0,
            fileSize: file.fileSize,
            modifiedAt: file.modifiedAt,
            trackNumber: meta?.trackNumber,
            discNumber: meta?.discNumber,
            needsDownload: file.needsDownload,
            containerHint: file.containerHint
        )
        let chapters: [Chapter]
        if let embedded = meta?.chapters, !embedded.isEmpty {
            chapters = embedded.map { Chapter(title: $0.title, trackIndex: 0, start: $0.start, duration: $0.duration) }
        } else {
            chapters = [Chapter(title: title, trackIndex: 0, start: 0, duration: track.duration)]
        }

        var artwork: [ArtworkCandidate] = []
        if meta?.hasArtwork == true {
            artwork.append(ArtworkCandidate(kind: .embedded, relativePath: file.relativePath))
        }
        let images = rankedImages(in: root, preferStem: file.stem, input: input)
        if isBookFolder {
            artwork += images.map { ArtworkCandidate(kind: .imageFile, relativePath: $0) }
        } else if let match = images.first(where: { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.normalizedForMatching == file.stem.normalizedForMatching }) {
            artwork.append(ArtworkCandidate(kind: .imageFile, relativePath: match))
        }

        let narrator = validNarrator(nonGeneric(meta?.composer), author: author) ?? naming.narrator ?? parsedName.narrator
        let book = Book(
            id: Book.makeID(sourceID: input.sourceID, relativePath: file.relativePath, groupKey: groupKey),
            sourceID: input.sourceID,
            relativePath: file.relativePath,
            kind: .singleFile,
            title: title,
            author: author,
            series: series,
            seriesIndex: seriesIndex,
            narrator: narrator == author ? nil : narrator,
            year: meta?.year ?? parsedName.year,
            tracks: [track],
            chapters: chapters,
            artworkID: nil,
            addedAt: input.now,
            totalBytes: file.fileSize
        )
        return BookDraft(book: book, artworkCandidates: artwork)
    }

    // MARK: - Ordering

    static func orderedTracks(_ files: [ScannedFile], discByFile: [String: Int]) -> [ScannedFile] {
        func disc(_ file: ScannedFile) -> Int { discByFile[file.relativePath] ?? file.metadata?.discNumber ?? 0 }
        let numbered = files.compactMap { file in file.metadata?.trackNumber.map { "\(disc(file))-\($0)" } }
        let useTrackNumbers = numbered.count == files.count && Set(numbered).count == files.count
        return files.sorted { a, b in
            let da = disc(a), db = disc(b)
            if da != db { return da < db }
            if useTrackNumbers, let ta = a.metadata?.trackNumber, let tb = b.metadata?.trackNumber, ta != tb {
                return ta < tb
            }
            return a.relativePath.naturallyPrecedes(b.relativePath)
        }
    }

    static func buildChapters(files: [ScannedFile], tracks: [Track], bookTitle: String, author: String?) -> [Chapter] {
        let rawTitles = files.map { ($0.metadata?.title ?? $0.stem).cleanedDisplayName }
        let titles = replaceJunkTitles(cleanChapterTitles(rawTitles, bookTitle: bookTitle, author: author), discs: tracks.map(\.discNumber))
        var chapters: [Chapter] = []
        for (index, file) in files.enumerated() {
            if let embedded = file.metadata?.chapters, embedded.count > 1 {
                chapters += embedded.map { Chapter(title: $0.title, trackIndex: index, start: $0.start, duration: $0.duration) }
            } else {
                chapters.append(Chapter(title: titles[index], trackIndex: index, start: 0, duration: tracks[index].duration))
            }
        }
        return chapters
    }

    /// "Pride and Prejudice - 01 - Chapter 1" → "Chapter 1"; "01 Loomings" → "Loomings"; "07" → "Chapter 7".
    static func chapterTitle(for file: ScannedFile, index: Int, bookTitle: String) -> String {
        formatChapterTitle((file.metadata?.title ?? file.stem).cleanedDisplayName, index: index, bookTitle: bookTitle, author: nil)
    }

    /// Strips what every chapter in a book shares ("Crime and Punishment NA 12" → "12",
    /// "CD08-08 - Miguel de Cervantes - Don Quixote" → "CD08-08") before formatting each one.
    static func cleanChapterTitles(_ titles: [String], bookTitle: String, author: String?) -> [String] {
        var working = titles
        if working.count >= 3 {
            let prefix = boundaryTrimmedPrefix(commonPrefix(working))
            if prefix.count >= 10 || (prefix.count >= 4 && prefix.normalizedForMatching.contains(bookTitle.normalizedForMatching) && !bookTitle.isEmpty) {
                let stripped = working.map { String($0.dropFirst(prefix.count)) }
                if stripped.allSatisfy({ !NameParser.trimSeparators($0).isEmpty }) { working = stripped }
            }
            let suffix = boundaryTrimmedSuffix(commonSuffix(working))
            if suffix.count >= 6 {
                let stripped = working.map { String($0.dropLast(suffix.count)) }
                if stripped.allSatisfy({ !NameParser.trimSeparators($0).isEmpty }) { working = stripped }
            }
        }
        return working.enumerated().map { index, title in
            formatChapterTitle(title, index: index, bookTitle: bookTitle, author: author)
        }
    }

    /// Titles with fewer than three letters ("1a", "07") carry no information; name them by
    /// position instead — per disc when the book has discs.
    static func replaceJunkTitles(_ titles: [String], discs: [Int?]) -> [String] {
        var positionInDisc: [Int: Int] = [:]
        return titles.enumerated().map { index, title in
            let letters = title.filter(\.isLetter).count
            let isGenericChapter = title.hasPrefix("Chapter ") && Int(title.dropFirst(8)) != nil
            guard letters < 3 || isGenericChapter, let disc = discs[index], discs.compactMap({ $0 }).count == titles.count, Set(discs.compactMap { $0 }).count > 1 else {
                return letters < 3 ? "Chapter \(index + 1)" : title
            }
            positionInDisc[disc, default: 0] += 1
            return "Disc \(disc) · Track \(positionInDisc[disc] ?? 1)"
        }
    }

    private static let discTrackPattern: NSRegularExpression = {
        guard let compiled = try? NSRegularExpression(pattern: #"^(?:cd|disc|disk|d)\s*0*(\d+)\s*[-_. ]+\s*(?:track|tr|t)?\s*0*(\d+)$"#, options: [.caseInsensitive]) else {
            preconditionFailure("invalid disc/track regex")
        }
        return compiled
    }()

    static func formatChapterTitle(_ raw: String, index: Int, bookTitle: String, author: String?) -> String {
        var title = raw.cleanedDisplayName
        for phrase in [bookTitle, author].compactMap({ $0 }) where !phrase.isEmpty {
            if let range = title.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) {
                title.removeSubrange(range)
            }
        }
        title = NameParser.trimSeparators(title)
        title = title.replacingOccurrences(of: #"\s*-\s*-\s*"#, with: " - ", options: .regularExpression)
        title = NameParser.trimSeparators(title)

        let range = NSRange(title.startIndex..., in: title)
        if let match = discTrackPattern.firstMatch(in: title, range: range), let disc = Range(match.range(at: 1), in: title), let track = Range(match.range(at: 2), in: title) {
            return "Disc \(title[disc]) · Track \(title[track])"
        }
        if let number = Int(title) {
            return "Chapter \(number)"
        }
        title = title.replacingOccurrences(of: #"^[\s\d._\-–—)\]]+"#, with: "", options: .regularExpression).cleanedDisplayName
        return title.isEmpty ? "Chapter \(index + 1)" : title
    }

    static func commonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for string in strings.dropFirst() {
            while !prefix.isEmpty, !string.hasPrefix(prefix) { prefix.removeLast() }
            if prefix.isEmpty { break }
        }
        return prefix
    }

    static func commonSuffix(_ strings: [String]) -> String {
        guard var suffix = strings.first else { return "" }
        for string in strings.dropFirst() {
            while !suffix.isEmpty, !string.hasSuffix(suffix) { suffix.removeFirst() }
            if suffix.isEmpty { break }
        }
        return suffix
    }

    /// Cuts a raw common prefix back to the last separator so "Chapter 1" (from "Chapter 10"/"Chapter 11") becomes "Chapter ".
    private static func boundaryTrimmedPrefix(_ prefix: String) -> String {
        guard let cut = prefix.lastIndex(where: { !$0.isLetter && !$0.isNumber }) else { return "" }
        return String(prefix[...cut])
    }

    private static func boundaryTrimmedSuffix(_ suffix: String) -> String {
        guard let cut = suffix.firstIndex(where: { !$0.isLetter && !$0.isNumber }) else { return "" }
        return String(suffix[cut...])
    }

    // MARK: - Naming heuristics

    struct Naming: Equatable {
        var author: String?
        var series: String?
        var seriesIndex: Double?
        var narrator: String?
    }

    /// Author/series from tags, then the file/folder name, then the `Author/Series/Book`
    /// folder convention — including shelves like "James S. A. Corey - The Expanse Series".
    static func resolveNaming(bookDirectory: String, isBookFolder: Bool, tagAuthor rawTagAuthor: String?, parsedName: NameParser.Parsed) -> Naming {
        var ancestors = bookDirectory.split(separator: "/").map(String.init)
        if isBookFolder, !ancestors.isEmpty { ancestors.removeLast() }
        ancestors = ancestors.filter { !isGeneric($0) && discNumber(fromFolderName: $0) == nil }

        // "Narrated by X" in the artist tag is a narrator, not an author.
        var narrator: String?
        var tagAuthor = rawTagAuthor
        if let raw = rawTagAuthor, let narrated = NameParser.narratorIfNarratedBy(raw) {
            narrator = narrated
            tagAuthor = nil
        }

        // A structured folder name ("Robin Hobb - (Rain Wilds #01) The Dragon Keeper") names the
        // author on purpose. When the shelf above agrees, it beats an artist tag — which in rips is
        // often the narrator ("Saskia Butler").
        var author: String?
        let structured = parsedName.author != nil && (parsedName.series != nil || parsedName.seriesIndex != nil)
        if structured, let folderAuthor = parsedName.author {
            let confirmed = tagAuthor == nil
                || namesMatch(tagAuthor ?? "", folderAuthor)
                || ancestors.contains { namesMatch($0, folderAuthor) || NameParser.mentions(folderAuthor, in: $0) }
            if confirmed {
                author = folderAuthor
                if let displaced = tagAuthor, !namesMatch(displaced, folderAuthor), NameParser.looksLikePersonName(displaced) {
                    narrator = narrator ?? displaced
                }
            }
        }
        author = author ?? tagAuthor ?? parsedName.author
        var series = parsedName.series
        let index = parsedName.seriesIndex

        if author == nil {
            if ancestors.count >= 2 {
                author = NameParser.clean(ancestors[ancestors.count - 2])
                series = series ?? NameParser.cleanSeriesName(ancestors[ancestors.count - 1])
            } else if let only = ancestors.last {
                let parsedAncestor = NameParser.parse(only)
                if let ancestorAuthor = parsedAncestor.author {
                    author = ancestorAuthor
                    series = series ?? parsedAncestor.series ?? NameParser.cleanSeriesName(parsedAncestor.title)
                } else {
                    author = NameParser.clean(only)
                }
            }
        } else if let knownAuthor = author, series == nil {
            if let shelf = ancestors.lastIndex(where: { namesMatch($0, knownAuthor) || NameParser.mentions(knownAuthor, in: $0) }) {
                if let remainder = NameParser.seriesRemovingAuthor(knownAuthor, from: ancestors[shelf]), !namesMatch(remainder, knownAuthor) {
                    series = remainder
                } else if shelf + 1 < ancestors.count {
                    series = NameParser.cleanSeriesName(ancestors[shelf + 1])
                }
            } else if let shelf = ancestors.last {
                // A shelf that doesn't mention the tagged author is a series, not a person:
                // "Bobiverse", "The Expanse". Multi-word person names ("Robin Hobb") are left alone.
                let cleaned = NameParser.clean(shelf)
                let words = cleaned.split(separator: " ").count
                if words == 1 || !NameParser.looksLikePersonName(cleaned) {
                    series = NameParser.cleanSeriesName(cleaned)
                }
            }
        }
        return Naming(author: author?.cleanedDisplayName.nilIfEmpty, series: series?.cleanedDisplayName.nilIfEmpty, seriesIndex: index, narrator: narrator?.cleanedDisplayName.nilIfEmpty)
    }

    /// Legacy entry point kept for tests: folder convention only.
    static func inferHierarchy(bookDirectory: String, isBookFolder: Bool, tagAuthor: String?) -> (author: String?, series: String?) {
        let naming = resolveNaming(bookDirectory: bookDirectory, isBookFolder: isBookFolder, tagAuthor: tagAuthor, parsedName: NameParser.Parsed(title: ""))
        return (naming.author, naming.series)
    }

    /// "3 - The Title" → (3, "The Title"); "Book 2: Title" keeps its title but yields 2.
    static func parseSeriesIndex(from title: String) -> (Double?, String) {
        // "3 - Title", "03. Title", "2) Title" — but not "2001: A Space Odyssey" or "1984".
        let leading = #"^\s*(\d+(?:\.\d+)?)\s*[-–—._)\]]+\s*(.+)$"#
        if let regex = try? NSRegularExpression(pattern: leading) {
            let ns = title as NSString
            if let result = regex.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)), result.numberOfRanges >= 3 {
                let number = Double(ns.substring(with: result.range(at: 1)))
                let rest = ns.substring(with: result.range(at: 2)).cleanedDisplayName
                if let number, number < 1000, !rest.isEmpty { return (number, rest) }
            }
        }
        let inline = #"\b(?:book|vol(?:ume)?|part|#)\s*(\d+(?:\.\d+)?)\b"#
        if let regex = try? NSRegularExpression(pattern: inline, options: [.caseInsensitive]) {
            let ns = title as NSString
            if let result = regex.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)), result.numberOfRanges >= 2 {
                return (Double(ns.substring(with: result.range(at: 1))), title)
            }
        }
        return (nil, title)
    }

    /// Words in a lone file's name that carry no title information.
    static let junkStemWords: Set<String> = [
        "audiobook", "audiobooks", "audio", "book", "full", "complete", "unabridged", "abridged",
        "track", "part", "cd", "disc", "final", "mp3", "m4b", "m4a", "file", "untitled",
    ]

    /// For a folder holding exactly one audio file: is the folder the book ("Dune/dune_full.mp3")
    /// or the shelf ("Mary Shelley/Frankenstein.mp3")? The file name decides — if it has words of
    /// its own beyond the folder name and filler, it's the title.
    static func singleFileTitle(stem: String, folderName: String) -> (title: String, folderIsBook: Bool) {
        let folderWords = Set(folderName.normalizedForMatching.split(separator: " ").map(String.init))
        let substantive = stem.normalizedForMatching.split(separator: " ").map(String.init).filter { word in
            !junkStemWords.contains(word) && !folderWords.contains(word) && word.rangeOfCharacter(from: .letters) != nil
        }
        if substantive.isEmpty {
            return (folderName.cleanedDisplayName, true)
        }
        let title = titleRemovingFolderName(from: stem, folderName: folderName)
        return title.isEmpty ? (folderName.cleanedDisplayName, true) : (title, false)
    }

    /// "Dune - Frank Herbert" in folder "Frank Herbert" → "Dune".
    static func titleRemovingFolderName(from stem: String, folderName: String) -> String {
        var title = stem.cleanedDisplayName
        let folder = folderName.cleanedDisplayName
        if !folder.isEmpty, let range = title.range(of: folder, options: [.caseInsensitive, .diacriticInsensitive]) {
            title.removeSubrange(range)
        }
        title = title.replacingOccurrences(of: #"\(\s*\)|\[\s*\]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"^[\s\-–—_.:,]+|[\s\-–—_.:,]+$"#, with: "", options: .regularExpression)
        return title.cleanedDisplayName
    }

    /// "Disc 1", "CD02", "Part_3", and suffix forms like "The E-Myth Revisited (Disc 6)" or "Title - CD 2".
    static func discNumber(fromFolderName name: String) -> Int? {
        let patterns = [
            #"^(?:cd|disc|disk|part|pt|volume|vol)[\s._-]*(\d+)$"#,
            #"[\s(\[-](?:cd|disc|disk)[\s._-]*(\d+)[)\]]?\s*$"#,
        ]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
                return Int(ns.substring(with: match.range(at: 1)))
            }
        }
        return nil
    }

    static func isGeneric(_ name: String) -> Bool {
        genericFolderNames.contains(name.normalizedForMatching)
    }

    static func nonGeneric(_ value: String?) -> String? {
        guard let value = value?.nilIfEmpty, !isGeneric(value) else { return nil }
        return value
    }

    static func namesMatch(_ a: String, _ b: String) -> Bool {
        let na = a.normalizedForMatching, nb = b.normalizedForMatching
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb || na.contains(nb) || nb.contains(na) { return true }
        return Set(na.split(separator: " ")) == Set(nb.split(separator: " "))
    }

    static func normalizedAlbum(_ file: ScannedFile) -> String {
        nonGeneric(file.metadata?.album)?.normalizedForMatching ?? ""
    }

    static func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: (count: Int, original: String)] = [:]
        for value in values {
            let key = value.normalizedForMatching
            counts[key, default: (0, value)].count += 1
        }
        return counts.values.max { $0.count < $1.count }?.original.cleanedDisplayName
    }

    static func mostCommonInt(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let counts = Dictionary(grouping: values) { $0 }.mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    private static func rankedImages(in directory: String, preferStem: String?, input: Input) -> [String] {
        guard let images = input.imagesByDirectory[directory], !images.isEmpty else { return [] }
        func rank(_ path: String) -> Int {
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.normalizedForMatching
            if let preferStem, stem == preferStem.normalizedForMatching { return 0 }
            if let index = AudioFileTypes.coverStems.firstIndex(where: { stem.hasPrefix($0) }) { return 1 + index }
            return 100
        }
        return images.sorted { rank($0) < rank($1) || (rank($0) == rank($1) && $0.naturallyPrecedes($1)) }
    }
}
