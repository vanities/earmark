import AVFoundation
import Foundation
import os
import ShelfKit

// MARK: - NAS

/// SMB servers: their clients (one per server, kept for the app's life), the password in the
/// Keychain, and what the player streams a remote track through.
extension LibraryModel {
    static func keychainKey(for serverID: UUID) -> String { "nas.\(serverID.uuidString)" }

    func server(id: UUID) -> NASServer? {
        nasServers.first { $0.id == id }
    }

    func server(for book: Book) -> NASServer? {
        guard let serverID = source(for: book)?.serverID else { return nil }
        return server(id: serverID)
    }

    func isRemote(_ book: Book) -> Bool {
        source(for: book)?.kind == .smb
    }

    func client(forServer id: UUID) -> NASClient? {
        if let client = nasClients[id] { return client }
        guard let server = server(id: id), let password = KeychainStore.get(Self.keychainKey(for: id)) else {
            Logger.nas.error("[nas] no credentials for server \(id.uuidString, privacy: .public)")
            return nil
        }
        do {
            let client = try NASClient(server: server, password: password)
            nasClients[id] = client
            return client
        } catch {
            Logger.nas.error("[nas] client init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func client(for book: Book) -> NASClient? {
        guard let serverID = source(for: book)?.serverID else { return nil }
        return client(forServer: serverID)
    }

    /// Connects, verifies the folder is listable, stores the password, and starts the first scan.
    func addNAS(_ server: NASServer, password: String) async throws {
        Logger.nas.info("[nas] adding \(server.displayLocation, privacy: .public)")
        let client = try NASClient(server: server, password: password)
        try await client.connect()
        _ = try await client.list("")
        try KeychainStore.set(password, for: Self.keychainKey(for: server.id))
        nasClients[server.id] = client
        nasServers.removeAll { $0.id == server.id }
        nasServers.append(server)
        nasStatus[server.id] = .online
        addRemoteSource(LibrarySource(id: UUID(), kind: .smb, displayName: server.name, bookmark: nil, addedAt: .now, serverID: server.id))
    }

    /// Streams remote tracks through `SMBResourceLoader`; local tracks read the file directly.
    func playbackSource(forTrack track: Track, in book: Book) -> PlaybackSource? {
        guard let source = source(for: book) else { return nil }
        if source.kind == .smb {
            guard let serverID = source.serverID, let client = client(forServer: serverID) else { return nil }
            let (asset, loader) = client.makeAsset(relativePath: track.relativePath, size: track.fileSize, preciseTiming: false, containerHint: track.containerHint)
            return PlaybackSource(asset: asset, loader: loader, isRemote: true, serverName: client.server.name)
        }
        guard let url = url(forTrack: track, in: book) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return PlaybackSource(asset: asset, loader: nil, isRemote: false, serverName: nil)
    }
}
