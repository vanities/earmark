import Foundation

/// Reads ID3v2 tags and estimates duration from an MP3's first few hundred kilobytes.
/// AVFoundation needs to pull a whole MP3 across the network to do the same, so remote
/// (SMB) scans use this first and fall back to AVFoundation only when parsing fails.
enum QuickTagReader {
    /// How much to fetch before knowing the tag size. Covers most tags, including small cover art.
    static let initialWindow = 256 * 1024
    /// Audio bytes to keep after the tag so the first frame header (and Xing/Info) is present.
    static let frameWindow = 64 * 1024

    struct FrameInfo: Equatable {
        var offset: Int
        var bitrate: Int
        var sampleRate: Int
        var samplesPerFrame: Int
        var xingFrameCount: Int?
    }

    // MARK: - Sniffing

    /// "mp3" for ID3/MPEG-audio headers, "mp4" for ISO base media (ftyp), nil when unsure.
    static func container(of head: Data) -> String? {
        guard head.count >= 12 else { return nil }
        let b = [UInt8](head.prefix(12))
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return "mp3" } // "ID3"
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return "mp3" }   // MPEG frame sync
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "mp4" } // "ftyp"
        if b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43 { return "flac" } // "fLaC"
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 { return "wav" } // "RIFF"
        return nil
    }

    // MARK: - Entry points

    /// Total bytes needed from the file start: the whole ID3v2 tag plus a frame window.
    static func requiredLength(_ head: Data) -> Int {
        (id3TagSize(head) ?? 0) + frameWindow
    }

    static func parseMP3(head: Data, fileSize: Int64) -> AudioMetadata? {
        let bytes = [UInt8](head)
        var meta = AudioMetadata()
        var audioStart = 0
        if let tagSize = id3TagSize(head) {
            parseID3v2(bytes, into: &meta)
            audioStart = min(tagSize, bytes.count)
        }
        guard let frame = firstFrame(in: bytes, from: audioStart) else { return nil }
        if let frames = frame.xingFrameCount, frames > 0 {
            meta.duration = Double(frames) * Double(frame.samplesPerFrame) / Double(frame.sampleRate)
        } else if frame.bitrate > 0 {
            let audioBytes = max(0, fileSize - Int64(frame.offset))
            meta.duration = Double(audioBytes) * 8 / Double(frame.bitrate)
        }
        return meta
    }

    // MARK: - ID3v2

    /// Size of the ID3v2 tag including its header (and footer), or nil when there is none.
    static func id3TagSize(_ data: Data) -> Int? {
        guard data.count >= 10 else { return nil }
        let b = [UInt8](data.prefix(10))
        guard b[0] == 0x49, b[1] == 0x44, b[2] == 0x33, b[3] < 0xFF, b[4] < 0xFF else { return nil }
        let size = syncsafe(b[6], b[7], b[8], b[9])
        let footer = (b[5] & 0x10) != 0 ? 10 : 0
        return 10 + size + footer
    }

    private static func parseID3v2(_ b: [UInt8], into meta: inout AudioMetadata) {
        guard b.count >= 10 else { return }
        let version = Int(b[3])
        let flags = b[5]
        let tagEnd = min(b.count, 10 + syncsafe(b[6], b[7], b[8], b[9]))
        var pos = 10
        if flags & 0x40 != 0, pos + 4 <= tagEnd {
            // Extended header: v2.4 stores a syncsafe size that includes itself; v2.3 excludes the 4 size bytes.
            let extSize = version == 4 ? syncsafe(b[pos], b[pos + 1], b[pos + 2], b[pos + 3]) : Int(be32(b, pos)) + 4
            pos += max(4, extSize)
        }
        let idLength = version == 2 ? 3 : 4
        let headerLength = version == 2 ? 6 : 10
        while pos + headerLength <= tagEnd {
            let idBytes = b[pos..<pos + idLength]
            guard let first = idBytes.first, first != 0 else { break }
            let id = String(decoding: idBytes, as: UTF8.self)
            let size: Int
            switch version {
            case 2: size = Int(b[pos + 3]) << 16 | Int(b[pos + 4]) << 8 | Int(b[pos + 5])
            case 4: size = syncsafe(b[pos + 4], b[pos + 5], b[pos + 6], b[pos + 7])
            default: size = Int(be32(b, pos + 4))
            }
            let frameFlags = version == 2 ? 0 : Int(b[pos + 9])
            let bodyStart = pos + headerLength
            let bodyEnd = bodyStart + size
            guard size > 0, bodyEnd <= tagEnd else { break }
            var body = Array(b[bodyStart..<bodyEnd])
            if version == 4 {
                if frameFlags & 0x01 != 0, body.count >= 4 { body.removeFirst(4) } // data length indicator
                if frameFlags & 0x02 != 0 { body = unsynchronised(body) }
            }
            apply(frameID: id, body: body, to: &meta)
            pos = bodyEnd
        }
    }

    private static func apply(frameID id: String, body: [UInt8], to meta: inout AudioMetadata) {
        switch id {
        case "TIT2", "TT2": meta.title = text(body) ?? meta.title
        case "TPE1", "TP1": meta.artist = text(body) ?? meta.artist
        case "TPE2", "TP2": meta.albumArtist = text(body) ?? meta.albumArtist
        case "TALB", "TAL": meta.album = text(body) ?? meta.album
        case "TCOM", "TCM": meta.composer = text(body) ?? meta.composer
        case "TCON", "TCO": meta.genre = text(body) ?? meta.genre
        case "TRCK", "TRK":
            if let raw = text(body) {
                let parts = MetadataReader.parseFraction(raw)
                meta.trackNumber = parts.0 ?? meta.trackNumber
                meta.trackTotal = parts.1 ?? meta.trackTotal
            }
        case "TPOS", "TPA":
            if let raw = text(body) { meta.discNumber = MetadataReader.parseFraction(raw).0 ?? meta.discNumber }
        case "TYER", "TDRC", "TORY", "TDOR", "TYE":
            if let raw = text(body), let year = MetadataReader.year(from: raw) { meta.year = meta.year ?? year }
        case "APIC", "PIC": meta.hasArtwork = true
        case "COMM", "COM":
            // encoding(1) + language(3) + short description(null-terminated) + text
            if body.count > 4 {
                let encoding = body[0]
                var rest = Array(body[4...])
                let terminator: [UInt8] = (encoding == 1 || encoding == 2) ? [0, 0] : [0]
                if let range = firstRange(of: terminator, in: rest) { rest = Array(rest[(range + terminator.count)...]) }
                meta.comment = meta.comment ?? text([encoding] + rest)
            }
        default: break
        }
    }

    /// Decodes an ID3 text frame body: encoding byte + string (first of any null-separated list).
    static func text(_ body: [UInt8]) -> String? {
        guard let encoding = body.first else { return nil }
        let payload = Data(body.dropFirst())
        let decoded: String?
        switch encoding {
        case 1: decoded = String(data: payload, encoding: .utf16) ?? String(data: payload, encoding: .utf16LittleEndian)
        case 2: decoded = String(data: payload, encoding: .utf16BigEndian)
        case 3: decoded = String(data: payload, encoding: .utf8)
        default: decoded = String(data: payload, encoding: .isoLatin1)
        }
        guard let decoded else { return nil }
        return decoded.split(separator: "\0", omittingEmptySubsequences: true).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    // MARK: - MPEG frames

    static func firstFrame(in b: [UInt8], from start: Int) -> FrameInfo? {
        var i = max(0, start)
        while i + 4 <= b.count {
            if b[i] == 0xFF, (b[i + 1] & 0xE0) == 0xE0, let header = parseHeader(b, at: i) {
                // Require the following frame to sync too, so random 0xFF bytes in junk don't fool us.
                let next = i + header.frameLength
                if next + 2 <= b.count, !(b[next] == 0xFF && (b[next + 1] & 0xE0) == 0xE0) {
                    i += 1
                    continue
                }
                let sideInfo = header.isVersion1 ? (header.channels == 1 ? 17 : 32) : (header.channels == 1 ? 9 : 17)
                let x = i + 4 + sideInfo
                var xingFrames: Int?
                if x + 8 <= b.count {
                    let tag = Array(b[x..<x + 4])
                    if tag == [0x58, 0x69, 0x6E, 0x67] || tag == [0x49, 0x6E, 0x66, 0x6F] { // "Xing" / "Info"
                        let flags = be32(b, x + 4)
                        if flags & 0x1 != 0, x + 12 <= b.count { xingFrames = Int(be32(b, x + 8)) }
                    }
                }
                return FrameInfo(offset: i, bitrate: header.bitrate, sampleRate: header.sampleRate, samplesPerFrame: header.samplesPerFrame, xingFrameCount: xingFrames)
            }
            i += 1
        }
        return nil
    }

    private struct Header {
        var isVersion1: Bool
        var bitrate: Int
        var sampleRate: Int
        var channels: Int
        var samplesPerFrame: Int
        var frameLength: Int
    }

    private static let bitratesV1L1 = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
    private static let bitratesV1L2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
    private static let bitratesV1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let bitratesV2L1 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
    private static let bitratesV2L23 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    private static func parseHeader(_ b: [UInt8], at i: Int) -> Header? {
        let b1 = b[i + 1], b2 = b[i + 2], b3 = b[i + 3]
        let versionBits = (b1 >> 3) & 0x03 // 0 = MPEG 2.5, 1 = reserved, 2 = MPEG 2, 3 = MPEG 1
        let layerBits = (b1 >> 1) & 0x03 // 1 = Layer III, 2 = Layer II, 3 = Layer I
        let bitrateIndex = Int(b2 >> 4)
        let sampleIndex = Int((b2 >> 2) & 0x03)
        guard versionBits != 1, layerBits != 0, bitrateIndex != 0, bitrateIndex != 15, sampleIndex != 3 else { return nil }
        let padding = Int((b2 >> 1) & 0x01)
        let channels = (b3 >> 6) & 0x03 == 3 ? 1 : 2
        let isV1 = versionBits == 3
        let layer = layerBits == 3 ? 1 : (layerBits == 2 ? 2 : 3)
        let table: [Int]
        if isV1 {
            table = layer == 1 ? bitratesV1L1 : (layer == 2 ? bitratesV1L2 : bitratesV1L3)
        } else {
            table = layer == 1 ? bitratesV2L1 : bitratesV2L23
        }
        let bitrate = table[bitrateIndex] * 1000
        let rates = isV1 ? [44100, 48000, 32000] : (versionBits == 2 ? [22050, 24000, 16000] : [11025, 12000, 8000])
        let sampleRate = rates[sampleIndex]
        let samplesPerFrame = layer == 1 ? 384 : (layer == 2 ? 1152 : (isV1 ? 1152 : 576))
        let frameLength = layer == 1
            ? (12 * bitrate / sampleRate + padding) * 4
            : (samplesPerFrame / 8 * bitrate / sampleRate + padding)
        guard frameLength > 4 else { return nil }
        return Header(isVersion1: isV1, bitrate: bitrate, sampleRate: sampleRate, channels: channels, samplesPerFrame: samplesPerFrame, frameLength: frameLength)
    }

    // MARK: - Bytes

    private static func syncsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7F) << 21 | Int(b & 0x7F) << 14 | Int(c & 0x7F) << 7 | Int(d & 0x7F)
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func unsynchronised(_ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        var i = 0
        while i < body.count {
            out.append(body[i])
            if body[i] == 0xFF, i + 1 < body.count, body[i + 1] == 0x00 { i += 1 }
            i += 1
        }
        return out
    }

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<i + needle.count]) == needle {
            return i
        }
        return nil
    }
}
