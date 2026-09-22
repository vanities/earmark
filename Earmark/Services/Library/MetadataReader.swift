import AVFoundation
import Foundation
import os
import ShelfKit

struct EmbeddedChapter: Codable, Hashable, Sendable {
    var title: String
    var start: TimeInterval
    var duration: TimeInterval
}

/// Everything we pull out of an audio file's tags. Cached per file by size + mtime.
struct AudioMetadata: Codable, Hashable, Sendable {
    var duration: TimeInterval = 0
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var comment: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var hasArtwork = false
    var chapters: [EmbeddedChapter] = []
}

/// Reads tags, duration, chapters, and artwork with AVFoundation's async loading APIs.
struct MetadataReader: Sendable {
    func read(url: URL) async throws -> AudioMetadata {
        try await read(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]), name: url.lastPathComponent)
    }

    /// Reads from any asset, including SMB-backed ones built by `NASClient.makeAsset`.
    func read(asset: AVURLAsset, name: String) async throws -> AudioMetadata {
        let sw = Stopwatch()
        let (duration, common, formats) = try await asset.load(.duration, .commonMetadata, .availableMetadataFormats)

        var meta = AudioMetadata()
        let seconds = CMTimeGetSeconds(duration)
        meta.duration = seconds.isFinite && seconds > 0 ? seconds : 0

        for item in common {
            await apply(commonItem: item, to: &meta)
        }
        for format in formats {
            let items = try await asset.loadMetadata(for: format)
            for item in items {
                await apply(formatItem: item, to: &meta)
            }
        }
        meta.chapters = await readChapters(from: asset)

        Logger.metadata.debug("[metadata] \(name, privacy: .public) dur=\(meta.duration, format: .fixed(precision: 1))s chapters=\(meta.chapters.count) art=\(meta.hasArtwork) in \(sw.ms, format: .fixed(precision: 0))ms")
        return meta
    }

    /// Embedded cover art, if any. Loaded separately so scanning stays cheap.
    func artworkData(url: URL) async -> Data? {
        await artworkData(asset: AVURLAsset(url: url))
    }

    func artworkData(asset: AVURLAsset) async -> Data? {
        guard let common = try? await asset.load(.commonMetadata) else { return nil }
        for item in common where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    // MARK: - Items

    private func apply(commonItem item: AVMetadataItem, to meta: inout AudioMetadata) async {
        guard let key = item.commonKey else { return }
        switch key {
        case .commonKeyTitle:
            meta.title = await string(item) ?? meta.title
        case .commonKeyArtist:
            meta.artist = await string(item) ?? meta.artist
        case .commonKeyAlbumName:
            meta.album = await string(item) ?? meta.album
        case .commonKeyArtwork:
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                meta.hasArtwork = true
            }
        case .commonKeyCreationDate:
            if let raw = await string(item), let year = Self.year(from: raw) {
                meta.year = year
            }
        case .commonKeyDescription:
            meta.comment = await string(item) ?? meta.comment
        case .commonKeyType:
            meta.genre = await string(item) ?? meta.genre
        default:
            break
        }
    }

    private func apply(formatItem item: AVMetadataItem, to meta: inout AudioMetadata) async {
        guard let identifier = item.identifier else { return }
        switch identifier {
        case .id3MetadataBand, .iTunesMetadataAlbumArtist:
            meta.albumArtist = await string(item) ?? meta.albumArtist
        case .id3MetadataComposer, .iTunesMetadataComposer:
            meta.composer = await string(item) ?? meta.composer
        case .id3MetadataTrackNumber:
            if let raw = await string(item) {
                let parts = Self.parseFraction(raw)
                meta.trackNumber = parts.0 ?? meta.trackNumber
                meta.trackTotal = parts.1 ?? meta.trackTotal
            }
        case .iTunesMetadataTrackNumber:
            let parts = await packedPair(item)
            meta.trackNumber = parts.0 ?? meta.trackNumber
            meta.trackTotal = parts.1 ?? meta.trackTotal
        case .id3MetadataPartOfASet:
            if let raw = await string(item) {
                meta.discNumber = Self.parseFraction(raw).0 ?? meta.discNumber
            }
        case .iTunesMetadataDiscNumber:
            meta.discNumber = await packedPair(item).0 ?? meta.discNumber
        case .id3MetadataYear, .id3MetadataRecordingTime, .id3MetadataOriginalReleaseYear, .iTunesMetadataReleaseDate:
            if let raw = await string(item), let year = Self.year(from: raw) {
                meta.year = meta.year ?? year
            }
        case .id3MetadataContentType, .iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre:
            if meta.genre == nil { meta.genre = await string(item) }
        case .id3MetadataComments, .iTunesMetadataUserComment:
            if meta.comment == nil { meta.comment = await string(item) }
        default:
            break
        }
    }

    private func string(_ item: AVMetadataItem) async -> String? {
        guard let value = try? await item.load(.stringValue) else { return nil }
        return value.nilIfEmpty
    }

    /// iTunes-style `trkn`/`disk` atoms: big-endian 16-bit pairs padded to 8 (or 6) bytes.
    private func packedPair(_ item: AVMetadataItem) async -> (Int?, Int?) {
        if let number = try? await item.load(.numberValue) {
            return (number.intValue, nil)
        }
        if let data = try? await item.load(.dataValue), data.count >= 4 {
            let bytes = [UInt8](data)
            let number = Int(bytes[2]) << 8 | Int(bytes[3])
            let total = bytes.count >= 6 ? Int(bytes[4]) << 8 | Int(bytes[5]) : nil
            return (number > 0 ? number : nil, (total ?? 0) > 0 ? total : nil)
        }
        if let raw = try? await item.load(.stringValue) {
            return Self.parseFraction(raw)
        }
        return (nil, nil)
    }

    // MARK: - Chapters

    private func readChapters(from asset: AVURLAsset) async -> [EmbeddedChapter] {
        var languages = Locale.preferredLanguages
        if languages.isEmpty { languages = ["en"] }
        var groups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)) ?? []
        if groups.isEmpty, let locales = try? await asset.load(.availableChapterLocales) {
            for locale in locales {
                groups = (try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])) ?? []
                if !groups.isEmpty { break }
            }
        }

        var chapters: [EmbeddedChapter] = []
        for (index, group) in groups.enumerated() {
            let start = CMTimeGetSeconds(group.timeRange.start)
            let duration = CMTimeGetSeconds(group.timeRange.duration)
            guard start.isFinite, duration.isFinite, duration > 0 else { continue }
            var title: String?
            for item in group.items where item.commonKey == .commonKeyTitle {
                title = await string(item)
                if title != nil { break }
            }
            if title == nil {
                for item in group.items {
                    if let value = await string(item) {
                        title = value
                        break
                    }
                }
            }
            chapters.append(EmbeddedChapter(title: title ?? "Chapter \(index + 1)", start: start, duration: duration))
        }
        return chapters
    }

    // MARK: - Parsing

    /// "3/12" → (3, 12); "7" → (7, nil).
    static func parseFraction(_ raw: String) -> (Int?, Int?) {
        let parts = raw.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let first = parts.first.flatMap { Int($0) }
        let second = parts.count > 1 ? Int(parts[1]) : nil
        return (first, second)
    }

    /// First plausible 4-digit year in a date-ish string.
    static func year(from raw: String) -> Int? {
        guard let range = raw.range(of: #"(1[89]|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(raw[range])
    }
}
