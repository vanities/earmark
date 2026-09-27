import SwiftUI
import ShelfKit

struct ReconnectLibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(DownloadManager.self) private var transfers
    @Environment(PlayerEngine.self) private var player
    var body: some View {
        List {
            NavigationLink("Choose a folder in Files") {
                ReconnectFolderView(sources: sources, busy: busy) { id, url in
                    guard let source = library.sources.first(where: { $0.id == id }) else { throw CocoaError(.fileReadNoSuchFile) }
                    try library.reconnectFolder(source, to: url)
                }
            }
            Section("NAS sources") {
                ForEach(library.nasServers) { server in
                    NavigationLink(server.name) {
                        NASRelocationView(server: server, files: files(for: server.id), busy: busy) { candidate in
                            guard let password = KeychainStore.get(LibraryModel.keychainKey(for: candidate.id)) else { throw CocoaError(.fileReadNoPermission) }
                            return try NASClient(server: candidate, password: password)
                        } apply: { candidate in
                            guard !busy else { throw CocoaError(.fileWriteUnknown) }
                            if player.book.flatMap({ library.server(for: $0)?.id }) == candidate.id { player.unload() }
                            try library.reconnectNAS(candidate)
                        }
                    }
                }
            }
        }.navigationTitle("Reconnect a source")
    }
    private var busy: Bool { library.isScanning || transfers.jobs.contains { $0.isActive } }
    private func files(for serverID: UUID) -> [RelinkFile] {
        let ids = Set(library.sources.filter { $0.serverID == serverID }.map(\.id))
        return sources.filter { ids.contains($0.id) }.flatMap(\.files)
    }
    private var sources: [ReconnectSource] {
        library.sources.filter { $0.kind == .folder || $0.kind == .smb }.map { source in
            let files = library.books.filter { $0.sourceID == source.id }.flatMap(\.tracks).map { RelinkFile(path: $0.relativePath, bytes: $0.fileSize) }
            return ReconnectSource(id: source.id, name: source.displayName, files: files)
        }
    }
}
