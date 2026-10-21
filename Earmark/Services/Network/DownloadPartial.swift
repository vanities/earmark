import CryptoKit
import Foundation
import os
import ShelfKit

/// A partial belongs to a specific source version, not just a path and byte count.
struct DownloadPartial: Sendable {
    struct Source: Codable, Equatable, Sendable {
        let endpoint: String
        let path: String
        let size: Int64
        let modifiedAt: Date?
        /// Bounded first/last-byte samples also catch common replacements with preserved dates.
        let sampleFingerprint: String
    }

    private struct Record: Codable { let format: Int; let source: Source }
    private struct Comparison {
        let file: FileHandle
        var checked: Int64 = 0
        var matches = true
        var cancelled = false
        var error: String?
    }
    let url: URL
    let source: Source
    let isComplete: Bool
    let retainedBytes: Int64

    static func metadataURL(for partial: URL) -> URL {
        partial.deletingLastPathComponent().appending(path: ".\(partial.lastPathComponent).source.json")
    }

    static func currentSource(client: NASClient, path: String) async throws -> Source {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let entries = try await client.list(parent)
        guard let entry = entries.first(where: { !$0.isDirectory && $0.name == name }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard entry.size >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let server = client.server
        let identity = try JSONEncoder().encode([server.id.uuidString, server.host, String(server.port),
                                                server.share, server.path, server.domain, server.username])
        let endpoint = digest(identity)
        let length = min(entry.size, 65_536)
        var sample = length > 0 ? try await client.readAll(path, maxBytes: length) : Data()
        guard Int64(sample.count) == length else { throw CocoaError(.fileReadCorruptFile) }
        if entry.size > length {
            let tail = OSAllocatedUnfairLock(initialState: Data())
            try await client.read(path, offset: entry.size - length, length: length) { bytes in
                tail.withLock { $0.append(bytes) }
                return true
            }
            let bytes = tail.withLock { $0 }
            guard Int64(bytes.count) == length else { throw CocoaError(.fileReadCorruptFile) }
            sample.append(bytes)
        }
        return Source(endpoint: endpoint, path: path, size: entry.size, modifiedAt: entry.modifiedAt,
                      sampleFingerprint: digest(sample))
    }

    static func prepare(at partial: URL, source: Source) throws -> Self {
        let manager = FileManager.default
        try manager.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        let attributes = try? manager.attributesOfItem(atPath: partial.path)
        let count = (attributes?[.size] as? NSNumber)?.int64Value
        let metadata = metadataURL(for: partial)
        let saved = (try? Data(contentsOf: metadata)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        // Old builds have no source record. Unknown timestamps cannot establish a stable version.
        let resumable = source.modifiedAt != nil && saved?.format == 1 && saved?.source == source
            && count.map { $0 >= 0 && $0 <= source.size } == true
        if count != nil, !resumable {
            try manager.removeItem(at: partial)
            Logger.downloads.info("[downloads] restarting unverified or changed partial \(source.path, privacy: .public)")
        }
        try JSONEncoder().encode(Record(format: 1, source: source)).write(to: metadata, options: .atomic)
        return Self(url: partial, source: source, isComplete: resumable && count == source.size,
                    retainedBytes: resumable ? (count ?? 0) : 0)
    }

    /// Size, dates and samples are not immutable version identifiers. Verify every retained
    /// byte before appending, without buffering the prefix or rewriting it on this device.
    func verifyingRetainedBytes(client: NASClient, shouldContinue: @escaping @Sendable () -> Bool) async throws -> Self {
        guard retainedBytes > 0 else { return self }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let comparison = OSAllocatedUnfairLock(initialState: Comparison(file: file))
        try await client.read(source.path, offset: 0, length: retainedBytes) { chunk in
            comparison.withLock { state in
                guard shouldContinue() else { state.cancelled = true; return false }
                do {
                    let local = try state.file.read(upToCount: chunk.count) ?? Data()
                    state.checked += Int64(chunk.count)
                    state.matches = local == chunk
                    return state.matches
                } catch {
                    state.error = error.localizedDescription
                    return false
                }
            }
        }
        let result = comparison.withLock { ($0.checked, $0.matches, $0.cancelled, $0.error) }
        if result.2 { throw CancellationError() }
        if let error = result.3 {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The partial download couldn't be verified: \(error)"])
        }
        guard result.1, result.0 == retainedBytes else {
            try FileManager.default.removeItem(at: url)
            Logger.downloads.info("[downloads] retained bytes changed for \(source.path, privacy: .public); restarting")
            return Self(url: url, source: source, isComplete: false, retainedBytes: 0)
        }
        return self
    }

    func validate(client: NASClient) async throws {
        // URL resource values can cache a partial's size from before resumption.
        let received = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard received == source.size else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "The download of \((source.path as NSString).lastPathComponent) was incomplete. Please retry."])
        }
        let current = try await Self.currentSource(client: client, path: source.path)
        guard current == source else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "The file changed while it was downloading. Please retry."])
        }
    }

    func removeMetadata() {
        let metadata = Self.metadataURL(for: url)
        do { try FileManager.default.removeItem(at: metadata) } catch {
            Logger.downloads.warning("[downloads] couldn't remove partial metadata for \(source.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
