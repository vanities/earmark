import Foundation

/// Pulls author / series / index / narrator out of the names audiobook files actually
/// have — "Author - Series, Book 2 - Title", "Author - Series 03 - Title (48 KBps Unabridged)",
/// "Title꞉ Series, Book 1", "Title - read by Narrator". Pure functions, tested against real names.
enum NameParser {
    struct Parsed: Equatable, Sendable {
        var title: String
        var author: String?
        var series: String?
        var seriesIndex: Double?
        var narrator: String?
        var year: Int?

        /// Fields from `self`, falling back to `other` where `self` has nothing.
        func filling(from other: Parsed) -> Parsed {
            Parsed(title: title, author: author ?? other.author, series: series ?? other.series,
                   seriesIndex: seriesIndex ?? other.seriesIndex, narrator: narrator ?? other.narrator, year: year ?? other.year)
        }
    }

    // MARK: - Cleaning

    private static let junkPatterns: [NSRegularExpression] = [
        // "(48 KBps Unabridged)", "[Uncut]", "(Unabridged)", "{MP3}", "(Retail)"
        #"[(\[{][^)\]}]*\b(?:\d{2,3}\s?kbps|unabridged|unabr|abridged|uncut|retail|mp3|m4b|m4a|audiobook|complete|full|remastered)\b[^)\]}]*[)\]}]"#,
        #"\b\d{2,3}\s?kbps\b"#,
        #"\bunabr(?:idged)?\b"#,
        #"\babridged\b"#,
        #"\b(?:mp3|m4b|m4a|flac|audiobook)\b"#,
    ].map { regex($0, [.caseInsensitive]) }

    private static let seriesSuffixPatterns: [NSRegularExpression] = [
        #"\s+books?\s+\d+\s*[-–]\s*\d+$"#,
        #"\s+(?:series|trilogy|saga|collection|cycle|sequence|omnibus)$"#,
    ].map { regex($0, [.caseInsensitive]) }

    /// Patterns are compile-time constants; a typo is a programmer error, not a runtime condition.
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            preconditionFailure("invalid regex: \(pattern)")
        }
        return compiled
    }

    /// Strips bitrate/edition noise and normalizes separators. "Zelazny -- Amber -- 48kbps unabr" → "Zelazny - Amber".
    static func clean(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "꞉", with: ":")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        for regex in junkPatterns {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        text = text.replacingOccurrences(of: #"\s*-{2,}\s*"#, with: " - ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(\s*\)|\[\s*\]|\{\s*\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return trimSeparators(text)
    }

    /// Trims separators at both ends but keeps the period of a trailing initial ("Michael E.").
    static func trimSeparators(_ text: String) -> String {
        var trimmed = text.replacingOccurrences(of: #"^[\s\-.:,;]+"#, with: "", options: .regularExpression)
        while true {
            let stripped = trimmed.replacingOccurrences(of: #"[\s\-:,;]+$"#, with: "", options: .regularExpression)
            if stripped.hasSuffix("."), stripped.range(of: #"(?<![A-Za-z])[A-Za-z]\.$"#, options: .regularExpression) == nil {
                trimmed = String(stripped.dropLast())
                continue
            }
            trimmed = stripped
            break
        }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    /// "The Expanse Series" → "The Expanse"; "Malazan Book of the Fallen Series Books 01-10" → "Malazan Book of the Fallen".
    static func cleanSeriesName(_ raw: String) -> String? {
        var text = clean(raw)
        // "(Realm of the Elderlings #7-9) Tawny Man Trilogy" → keep the subseries after the range.
        if let match = parenSeriesRange.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let whole = Range(match.range, in: text) {
            let remainder = trimSeparators(String(text[whole.upperBound...]))
            if !remainder.isEmpty {
                text = remainder
            } else if let inner = Range(match.range(at: 1), in: text) {
                text = String(text[inner])
            }
        }
        for regex in seriesSuffixPatterns {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = trimSeparators(text)
        return text.isEmpty ? nil : text
    }

    // MARK: - Parsing

    private static let bracketYear = regex(#"\s*\[\s*Y\s*=\s*(\d{4})\s*\]"#, [.caseInsensitive])
    private static let authorParenSeriesTitle = regex(#"^(.+?)\s+-\s+\((.+?)\s+#\s*(\d+(?:\.\d+)?)\)\s+(.+)$"#)
    private static let parenSeriesRange = regex(#"\((.+?)\s+#\s*\d+(?:\.\d+)?\s*[-–]\s*\d+(?:\.\d+)?\)"#)
    private static let readBy = regex(#"[\s\-,(\[]*\b(?:read|narrated)\s+by\s+([A-Z][\w.'’-]+(?:\s+[A-Z][\w.'’-]+){0,3})\s*[)\]]?"#)
    private static let trailingParenName = regex(#"\s*\(([A-Z][\w.'’-]+(?:\s+[A-Z][\w.'’-]+){1,2})\)$"#)
    private static let authorSeriesBookTitle = regex(#"^(.+?)\s+-\s+(.+?),?\s+(?:Book|Bk\.?|Vol\.?|Volume|Part|No\.?|#)\s*(\d+(?:\.\d+)?)\s+-\s+(.+)$"#, [.caseInsensitive])
    private static let authorSeriesNumberTitle = regex(#"^(.+?)\s+-\s+(.+?)\s+(\d{1,3})\s*-\s+(.+)$"#)
    private static let titleColonSeriesBook = regex(#"^(.+?):\s+(.+?),?\s+(?:Book|Vol\.?|Volume|Part|#)\s*(\d+(?:\.\d+)?)$"#, [.caseInsensitive])
    private static let seriesBookTitle = regex(#"^(.+?),?\s+(?:Book|Vol\.?|Volume|Part)\s+(\d+(?:\.\d+)?)\s*[-:]\s+(.+)$"#, [.caseInsensitive])
    private static let twoParts = regex(#"^(.+?)\s+-\s+(.+)$"#)
    private static let numberWords = #"\d+(?:\.\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth"#
    /// "Ship of Magic: The Liveship Traders, Book One"
    private static let titleColonSeriesBookWord = regex(#"^(.+?):\s+(.+?),?\s+(?:Book|Vol\.?|Volume|Part|#)\s*("# + numberWords + #")$"#, [.caseInsensitive])
    /// "Dragon Haven: Volume Two of the Rain Wilds Chronicles"
    private static let titleColonVolumeOfSeries = regex(#"^(.+?):\s+(?:Volume|Book|Part)\s+("# + numberWords + #")\s+of\s+(?:the\s+)?(.+)$"#, [.caseInsensitive])
    /// "Rain Wilds Chronicles #01 - The Dragon Keeper"
    private static let seriesHashNumberTitle = regex(#"^(.+?)\s+#\s*(\d+(?:\.\d+)?)\s*[-:]\s+(.+)$"#)
    private static let narratedBy = regex(#"^\s*(?:narrated|read)\s+by\s+(.+)$"#, [.caseInsensitive])

    /// "one" → 1, "Second" → 2, "03" → 3.
    static func indexValue(_ raw: String) -> Double? {
        if let number = Double(raw) { return number }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
                     "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]
        return words[raw.lowercased()].map(Double.init)
    }

    /// Artist tags that actually name the narrator: "Narrated by Anne Flosnik" → "Anne Flosnik".
    static func narratorIfNarratedBy(_ text: String) -> String? {
        guard let match = narratedBy.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return trimSeparators(String(text[range])).nilIfEmpty
    }

    /// `knownAuthor` (from tags) disambiguates "A - B" names.
    static func parse(_ raw: String, knownAuthor: String? = nil) -> Parsed {
        var text = clean(raw)
        var parsed = Parsed(title: text)

        if let match = bracketYear.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let yearRange = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) {
            parsed.year = Int(text[yearRange])
            text.removeSubrange(whole)
            text = trimSeparators(text)
        }

        if let match = readBy.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let nameRange = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) {
            parsed.narrator = String(text[nameRange])
            text.removeSubrange(whole)
            text = trimSeparators(text)
        } else if let match = trailingParenName.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let nameRange = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) {
            let candidate = String(text[nameRange])
            if looksLikePersonName(candidate) {
                parsed.narrator = candidate
                text.removeSubrange(whole)
                text = trimSeparators(text)
            }
        }
        parsed.title = text

        func groups(_ regex: NSRegularExpression, _ count: Int) -> [String]? {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > count else { return nil }
            return (1...count).compactMap { Range(match.range(at: $0), in: text).map { trimSeparators(String(text[$0])) } }
        }

        // "Robin Hobb - (Tawny Man #01) Fool's Errand"
        if let g = groups(authorParenSeriesTitle, 4) {
            parsed.author = normalizePersonName(g[0]); parsed.series = cleanSeriesName(g[1]); parsed.seriesIndex = Double(g[2]); parsed.title = g[3]
            return parsed
        }
        if let g = groups(authorSeriesBookTitle, 4) {
            parsed.author = normalizePersonName(g[0]); parsed.series = cleanSeriesName(g[1]); parsed.seriesIndex = Double(g[2]); parsed.title = g[3]
            return parsed
        }
        if let g = groups(authorSeriesNumberTitle, 4), looksLikePersonName(g[0]) || (knownAuthor.map { BookGrouper.namesMatch($0, g[0]) } ?? false) {
            parsed.author = normalizePersonName(g[0]); parsed.series = cleanSeriesName(g[1]); parsed.seriesIndex = Double(g[2]); parsed.title = g[3]
            return parsed
        }
        if let g = groups(titleColonVolumeOfSeries, 3) {
            parsed.title = g[0]; parsed.seriesIndex = indexValue(g[1]); parsed.series = cleanSeriesName(g[2])
            return parsed
        }
        if let g = groups(titleColonSeriesBookWord, 3) {
            parsed.title = g[0]; parsed.series = cleanSeriesName(g[1]); parsed.seriesIndex = indexValue(g[2])
            return parsed
        }
        if let g = groups(titleColonSeriesBook, 3) {
            parsed.title = g[0]; parsed.series = cleanSeriesName(g[1]); parsed.seriesIndex = Double(g[2])
            return parsed
        }
        if let g = groups(seriesHashNumberTitle, 3) {
            parsed.series = cleanSeriesName(g[0]); parsed.seriesIndex = Double(g[1]); parsed.title = g[2]
            return parsed
        }
        if let g = groups(seriesBookTitle, 3) {
            parsed.series = cleanSeriesName(g[0]); parsed.seriesIndex = Double(g[1]); parsed.title = g[2]
            return parsed
        }
        if let g = groups(twoParts, 2) {
            let (a, b) = (g[0], g[1])
            if let knownAuthor {
                // Use the clean known author, not the matched segment — the segment may be padded
                // with series/edition junk ("Bobiverse, Book 4 by Dennis E. Taylor").
                if BookGrouper.namesMatch(a, knownAuthor) { parsed.author = normalizePersonName(knownAuthor); parsed.title = b; return parsed }
                if BookGrouper.namesMatch(b, knownAuthor) { parsed.author = normalizePersonName(knownAuthor); parsed.title = a; return parsed }
            }
            let aName = looksLikePersonName(a), bName = looksLikePersonName(b)
            if aName && !bName {
                parsed.author = normalizePersonName(a)
                parsed.title = b
            } else if bName && !aName {
                parsed.author = normalizePersonName(b)
                parsed.title = a
            } else if aName && bName {
                // Both could be names: the longer one is more likely the person ("Dune - Frank Herbert").
                if a.split(separator: " ").count >= b.split(separator: " ").count {
                    parsed.author = normalizePersonName(a)
                    parsed.title = b
                } else {
                    parsed.author = normalizePersonName(b)
                    parsed.title = a
                }
            }
            return parsed
        }
        return parsed
    }

    private static let nameStopWords: Set<String> = [
        "the", "a", "an", "of", "and", "or", "in", "on", "for", "to", "at", "by", "with", "from", "&", "vs", "is", "are", "my", "your", "his", "her", "its", "our", "their",
    ]
    private static let nameParticles: Set<String> = ["de", "van", "von", "der", "den", "da", "di", "la", "le", "du", "del", "dos", "das", "el", "al", "bin", "ibn", "mc", "mac", "st.", "jr.", "sr.", "iii", "ii"]

    /// "Frank Herbert", "James S. A. Corey", "Miguel de Cervantes" — but not "The Devils" or "Morals and Dogma".
    static func looksLikePersonName(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        guard (1...5).contains(words.count) else { return false }
        guard text.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        var capitalized = 0
        for word in words {
            let lower = word.lowercased()
            if nameStopWords.contains(lower) { return false }
            if nameParticles.contains(lower) { continue }
            guard let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
            capitalized += 1
        }
        return capitalized >= 1
    }

    /// "Gerber, Michael E." → "Michael E. Gerber". Leaves everything else alone.
    static func normalizePersonName(_ name: String) -> String {
        let parts = name.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, looksLikePersonName(parts[0]), looksLikePersonName(parts[1]) else { return name }
        return "\(parts[1]) \(parts[0])"
    }

    /// Words of `author` that appear in `text` as whole words (case-insensitive) — used to
    /// recognise "Zelazny -- Chronicles of Amber" as belonging to "Roger Zelazny".
    static func mentions(_ author: String, in text: String) -> Bool {
        let textWords = Set(text.normalizedForMatching.split(separator: " ").map(String.init))
        let authorWords = author.normalizedForMatching.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard let surname = authorWords.last else { return false }
        return textWords.contains(surname)
    }

    /// Removes the author's words from a shelf-folder name, leaving the series: "James S. A. Corey - The Expanse Series" → "The Expanse".
    static func seriesRemovingAuthor(_ author: String, from text: String) -> String? {
        var remainder = clean(text)
        for word in author.split(separator: " ").map(String.init) where word.count >= 2 {
            let escaped = NSRegularExpression.escapedPattern(for: word.replacingOccurrences(of: ".", with: ""))
            remainder = remainder.replacingOccurrences(of: #"(?i)\b"# + escaped + #"\.?\b"#, with: "", options: .regularExpression)
        }
        remainder = remainder.replacingOccurrences(of: #"^[\s\-.:,;]+|[\s\-.:,;]+$"#, with: "", options: .regularExpression)
        remainder = remainder.replacingOccurrences(of: #"\s*-\s*-\s*"#, with: " - ", options: .regularExpression)
        return cleanSeriesName(remainder)
    }
}
