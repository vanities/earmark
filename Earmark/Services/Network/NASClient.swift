import AMSMB2
import AVFoundation
import Foundation
import os

struct NASEntry: Hashable, Sendable {
    var name: String
    /// Relative to the server's library root.
    var relativePath: String
    var isDirectory: Bool
    var size: Int64
    var modifiedAt: Date?
}

enum NASError: LocalizedError {
    case invalidServer
    case unreachable(server: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            "The server address isn't valid."
        case .unreachable(let server, let underlying):
            "Couldn't reach \(server). Make sure this iPhone is on the same network (or VPN) as your NAS. (\(underlying))"
        }
    }
}

/// One SMB connection to one server. `SMB2Manager` serializes its own I/O on an internal
/// queue, so this wrapper only adds async ergonomics, reconnects, and path mapping.
final class NASClient: @unchecked Sendable {
    static let scheme = "earmark-smb"

    let server: NASServer
    private let manager: SMB2Manager
    private let connected = OSAllocatedUnfairLock(initialState: false)

    init(server: NASServer, password: String) throws {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = server.host
        if server.port != 445 { components.port = server.port }
        let credential = URLCredential(user: server.username, password: password, persistence: .forSession)
        guard let url = components.url, let manager = SMB2Manager(url: url, domain: server.domain, credential: credential) else {
            throw NASError.invalidServer
        }
        manager.timeout = 15
        self.server = server
        self.manager = manager
    }

    var isConnected: Bool { connected.withLock { $0 } }

    func connect() async throws {
        let sw = Stopwatch()
        do {
            try await manager.connectShare(name: server.share, encrypted: false)
            connected.withLock { $0 = true }
            Logger.nas.info("[nas] connected \(self.server.name, privacy: .public) share=\(self.server.share, privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
        } catch {
            connected.withLock { $0 = false }
            Logger.nas.error("[nas] connect failed host=\(self.server.host, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw NASError.unreachable(server: server.name, underlying: error.localizedDescription)
        }
    }

    func ensureConnected() async throws {
        if isConnected {
            do {
                try await manager.echo()
                return
            } catch {
                Logger.nas.notice("[nas] echo failed for \(self.server.name, privacy: .public) — reconnecting")
            }
        }
        try await connect()
    }

    func disconnect() async {
        try? await manager.disconnectShare(gracefully: true)
        connected.withLock { $0 = false }
    }

    // MARK: - Directory listing

    func list(_ relativePath: String) async throws -> [NASEntry] {
        try await ensureConnected()
        let sw = Stopwatch()
        let raw = try await manager.contentsOfDirectory(atPath: server.remotePath(for: relativePath), recursive: false)
        let entries = raw.compactMap { entry -> NASEntry? in
            guard let name = entry[.nameKey] as? String, !name.isEmpty, name != ".", name != ".." else { return nil }
            let isDirectory = (entry[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let size = (entry[.fileSizeKey] as? NSNumber)?.int64Value ?? (entry[.fileSizeKey] as? Int64) ?? 0
            let modified = entry[.contentModificationDateKey] as? Date
            let path = relativePath.isEmpty ? name : relativePath + "/" + name
            return NASEntry(name: name, relativePath: path, isDirectory: isDirectory, size: size, modifiedAt: modified)
        }
        Logger.nas.debug("[nas] list \(relativePath.isEmpty ? "/" : relativePath, privacy: .public) → \(entries.count) entries in \(sw.ms, format: .fixed(precision: 0))ms")
        return entries
    }

    // MARK: - Reading

    /// Streams `length` bytes from `offset`; `onChunk` returns false to stop early.
    func read(_ relativePath: String, offset: Int64, length: Int64, onChunk: @escaping @Sendable (Data) -> Bool) async throws {
        try await ensureConnected()
        let remaining = OSAllocatedUnfairLock(initialState: length)
        let remote = server.remotePath(for: relativePath)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            manager.contents(atPath: remote, offset: offset, fetchedData: { _, _, data in
                let slice: Data? = remaining.withLock { left in
                    guard left > 0 else { return nil }
                    let take = Int(min(Int64(data.count), left))
                    left -= Int64(take)
                    return take == data.count ? data : data.prefix(take)
                }
                guard let slice else { return false }
                let keepGoing = onChunk(slice)
                return keepGoing && remaining.withLock { $0 > 0 }
            }, completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Whole small files (cover images). Refuses anything over `maxBytes`.
    func readAll(_ relativePath: String, maxBytes: Int64 = 25_000_000) async throws -> Data {
        let collected = OSAllocatedUnfairLock(initialState: Data())
        try await read(relativePath, offset: 0, length: maxBytes) { chunk in
            collected.withLock { $0.append(chunk) }
            return true
        }
        return collected.withLock { $0 }
    }

    // MARK: - Downloading

    /// Copies a remote file to a local URL, reporting (bytes, total); return false from `progress` to cancel.
    func download(_ relativePath: String, to localURL: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        try await ensureConnected()
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let remote = server.remotePath(for: relativePath)
        let sw = Stopwatch()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            manager.downloadItem(atPath: remote, to: localURL, progress: progress) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        Logger.nas.info("[nas] downloaded \(relativePath, privacy: .public) in \(sw.seconds, format: .fixed(precision: 1))s")
    }

    // MARK: - AVFoundation bridge

    static func assetURL(serverID: UUID, relativePath: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = serverID.uuidString.lowercased()
        components.path = "/" + relativePath
        guard let url = components.url else {
            preconditionFailure("unrepresentable remote path: \(relativePath)")
        }
        return url
    }

    /// An asset that streams from this server through `SMBResourceLoader`. Keep the loader
    /// alive for as long as the asset is in use.
    func makeAsset(relativePath: String, size: Int64, preciseTiming: Bool = false) -> (asset: AVURLAsset, loader: SMBResourceLoader) {
        let url = Self.assetURL(serverID: server.id, relativePath: relativePath)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: preciseTiming])
        let loader = SMBResourceLoader(client: self, relativePath: relativePath, fileSize: size)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }
}
