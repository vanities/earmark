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

    /// Read chunk size. Each chunk is a bounded SMB read that runs to completion; we only ever
    /// stop *between* chunks. Aborting a libsmb2 read mid-stream (returning false from AMSMB2's
    /// streaming callbacks) crashed on device with a use-after-free in `read_cb`.
    static let chunkSize: Int64 = 1_048_576

    /// Delivers `length` bytes from `offset` in bounded chunks; `onChunk` returns false to stop
    /// after the current chunk.
    func read(_ relativePath: String, offset: Int64, length: Int64, onChunk: @escaping @Sendable (Data) -> Bool) async throws {
        try await ensureConnected()
        let remote = server.remotePath(for: relativePath)
        var position = offset
        let end = offset + length
        while position < end {
            let chunkEnd = min(end, position + Self.chunkSize)
            let data = try await manager.contents(atPath: remote, range: position..<chunkEnd, progress: nil)
            if data.isEmpty { break }
            position += Int64(data.count)
            if !onChunk(data) { break }
            if Int64(data.count) < chunkEnd - (position - Int64(data.count)) { break } // short read = EOF
        }
    }

    /// Whole small files (cover images, tag headers). Never reads past `maxBytes`.
    func readAll(_ relativePath: String, maxBytes: Int64 = 25_000_000) async throws -> Data {
        try await ensureConnected()
        let remote = server.remotePath(for: relativePath)
        return try await manager.contents(atPath: remote, range: Int64(0)..<maxBytes, progress: nil)
    }

    // MARK: - Downloading

    /// Copies a remote file to a local URL in bounded chunks, reporting (bytes, total); return
    /// false from `progress` to cancel between chunks.
    func download(_ relativePath: String, to localURL: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        try await ensureConnected()
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let total = try await fileSize(relativePath)
        let sw = Stopwatch()
        // Resume a partial file from a previous attempt instead of starting over.
        var position: Int64 = 0
        if let existing = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(existing) < total {
            position = Int64(existing)
            Logger.nas.info("[nas] resuming \(relativePath, privacy: .public) at \(position) of \(total)")
        } else {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(position))
        let remote = server.remotePath(for: relativePath)
        while position < total {
            let chunkEnd = min(total, position + Self.chunkSize * 4)
            let data = try await manager.contents(atPath: remote, range: position..<chunkEnd, progress: nil)
            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            position += Int64(data.count)
            if !progress(position, total) {
                throw CancellationError()
            }
        }
        Logger.nas.info("[nas] downloaded \(relativePath, privacy: .public) \(position) bytes in \(sw.seconds, format: .fixed(precision: 1))s")
    }

    // MARK: - Uploading

    /// Uploads a local file to `relativePath` on the share, creating parent folders first and
    /// clearing any partial remote file so the write starts clean. Reports (bytes, total); return
    /// false from `progress` to stop (AMSMB2 aborts the transfer).
    func upload(_ localURL: URL, to relativePath: String, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        try await ensureConnected()
        let remote = server.remotePath(for: relativePath)
        try await ensureDirectory((remote as NSString).deletingLastPathComponent)
        let total = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try? await manager.removeItem(atPath: remote)
        let sw = Stopwatch()
        try await manager.uploadItem(at: localURL, toPath: remote) { written in progress(written, total) }
        Logger.nas.info("[nas] uploaded \(relativePath, privacy: .public) \(total) bytes in \(sw.seconds, format: .fixed(precision: 1))s")
    }

    /// Size of a remote file, or nil when it isn't there (used to skip files already mirrored).
    func remoteSizeIfExists(_ relativePath: String) async -> Int64? {
        guard let size = try? await fileSize(relativePath), size > 0 else { return nil }
        return size
    }

    /// Creates each level of a directory path, ignoring "already exists".
    private func ensureDirectory(_ dir: String) async throws {
        guard !dir.isEmpty else { return }
        var path = ""
        for comp in dir.split(separator: "/").map(String.init) {
            path = path.isEmpty ? comp : path + "/" + comp
            try? await manager.createDirectory(atPath: path)
        }
    }

    func fileSize(_ relativePath: String) async throws -> Int64 {
        try await ensureConnected()
        let attrs = try await manager.attributesOfItem(atPath: server.remotePath(for: relativePath))
        return (attrs[.fileSizeKey] as? NSNumber)?.int64Value ?? (attrs[.fileSizeKey] as? Int64) ?? 0
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
    func makeAsset(relativePath: String, size: Int64, preciseTiming: Bool = false, containerHint: String? = nil) -> (asset: AVURLAsset, loader: SMBResourceLoader) {
        let url = Self.assetURL(serverID: server.id, relativePath: relativePath)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: preciseTiming])
        let loader = SMBResourceLoader(client: self, relativePath: relativePath, fileSize: size, containerHint: containerHint)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }
}
