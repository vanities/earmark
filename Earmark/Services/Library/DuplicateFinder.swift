import CryptoKit
import Foundation
import os
import ShelfKit

/// Size + SHA-256 of the first and last 256 KB. Fast enough for thousands of files
/// and practically collision-free for real audio.
struct FileFingerprint: Codable, Hashable, Sendable {
    var size: Int64
    var digest: String
}

struct DuplicateFile: Identifiable, Hashable, Sendable {
    var id: String { "\(sourceID.uuidString)|\(relativePath)" }
    var bookID: String
    var bookTitle: String
    var sourceID: UUID
    var relativePath: String
    var size: Int64
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Every file in these books matches another book file-for-file.
        case wholeBook
        /// The same file shows up in more than one place.
        case files
    }

    let id: String
    var kind: Kind
    var books: [Book]
    var files: [DuplicateFile]
    var wastedBytes: Int64
}

enum DuplicateFinder {
    static let sampleBytes = 256 * 1024

    static func trackKey(_ sourceID: UUID, _ relativePath: String) -> String {
        "\(sourceID.uuidString)|\(relativePath)"
    }

    static func fingerprint(url: URL) throws -> FileFingerprint {
        let size = Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let head = try handle.read(upToCount: sampleBytes) ?? Data()
        hasher.update(data: head)
        if size > Int64(sampleBytes) * 2 {
            try handle.seek(toOffset: UInt64(size - Int64(sampleBytes)))
            let tail = try handle.read(upToCount: sampleBytes) ?? Data()
            hasher.update(data: tail)
        }
        withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileFingerprint(size: size, digest: digest)
    }

    static func bookSignature(_ book: Book, fingerprints: [String: FileFingerprint]) -> String? {
        let digests = book.tracks.compactMap { fingerprints[trackKey(book.sourceID, $0.relativePath)]?.digest }
        guard !digests.isEmpty, digests.count == book.tracks.count else { return nil }
        return digests.sorted().joined(separator: ",")
    }

    static func duplicateGroups(books: [Book], fingerprints: [String: FileFingerprint]) -> [DuplicateGroup] {
        var bySignature: [String: [Book]] = [:]
        for book in books {
            if let signature = bookSignature(book, fingerprints: fingerprints) {
                bySignature[signature, default: []].append(book)
            }
        }
        var groups: [DuplicateGroup] = bySignature.values
            .filter { $0.count >= 2 }
            .map { matches in
                let sorted = matches.sorted { $0.addedAt < $1.addedAt }
                return DuplicateGroup(
                    id: "book:" + sorted[0].id,
                    kind: .wholeBook,
                    books: sorted,
                    files: [],
                    wastedBytes: Int64(sorted.count - 1) * sorted[0].totalBytes
                )
            }

        let covered = Set(groups.flatMap { $0.books.map(\.id) })
        var byDigest: [String: [DuplicateFile]] = [:]
        for book in books where !covered.contains(book.id) {
            for track in book.tracks {
                guard let fingerprint = fingerprints[trackKey(book.sourceID, track.relativePath)] else { continue }
                byDigest[fingerprint.digest, default: []].append(DuplicateFile(
                    bookID: book.id, bookTitle: book.title, sourceID: book.sourceID, relativePath: track.relativePath, size: track.fileSize
                ))
            }
        }
        for (digest, files) in byDigest where files.count >= 2 {
            groups.append(DuplicateGroup(
                id: "file:" + digest,
                kind: .files,
                books: [],
                files: files.sorted { $0.relativePath.naturallyPrecedes($1.relativePath) },
                wastedBytes: Int64(files.count - 1) * files[0].size
            ))
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }
}
