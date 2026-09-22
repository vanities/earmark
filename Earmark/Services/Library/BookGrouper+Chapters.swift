import Foundation
import ShelfKit

// MARK: - Ordering

/// Track order and chapter titles for a book being grouped: disc and track numbers, and
/// titles cleaned of what every chapter repeats (the book's name, "Track 01"…).
extension BookGrouper {
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
}
