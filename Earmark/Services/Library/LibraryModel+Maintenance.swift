import Foundation
import ShelfKit
import os

// Mutations for explicit backup restore, source reconnect and track arrangement.
extension LibraryModel {
    func snapshot() -> LibraryState {
        var state = LibraryState(sources: sources, books: books, progress: progress, hiddenBookIDs: hiddenBookIDs, lastBookID: lastBookID, nasServers: nasServers, customArtwork: customArtwork, coverChoices: coverChoices, writtenCovers: writtenCovers, metadataOverrides: metadataOverrides, bookmarks: bookmarks, readingLog: readingLog)
        state.deletedBookmarks = deletedBookmarks
        state.bookLists = bookLists
        state.sessions = sessions
        state.manualGroupings = manualGroupings
        state.tools = tools
        return state
    }

    func rehomeGroupings(removing id: UUID) {
        for index in manualGroupings.indices {
            manualGroupings[index].copySourceIDs.remove(id)
            if manualGroupings[index].sourceID == id,
               let replacement = sources.first(where: { manualGroupings[index].copySourceIDs.contains($0.id) }) {
                manualGroupings[index].sourceID = replacement.id
                manualGroupings[index].copySourceIDs.remove(replacement.id)
            }
        }
    }

    func reconnectNAS(_ server: NASServer) throws {
        guard !isScanning, let index = nasServers.firstIndex(where: { $0.id == server.id }) else { throw CocoaError(.fileWriteUnknown) }
        nasServers[index] = server; save()
        let old = nasClients.removeValue(forKey: server.id)
        Task { await old?.disconnect() }
        for source in sources where source.serverID == server.id { rescan(source.id) }
        Logger.nas.info("[reconnect] updated NAS source \(server.id.uuidString, privacy: .public)")
    }

    func reconnectFolder(_ source: LibrarySource, to url: URL) throws {
        guard !isScanning, let index = sources.firstIndex(where: { $0.id == source.id }),
              source.kind == .folder || source.kind == .smb else { throw CocoaError(.fileWriteUnknown) }
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for other in sources where other.id != source.id {
            guard let root = rootURL(for: other.id) else { continue }
            let existing = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard !candidate.hasPrefix(existing), !existing.hasPrefix(candidate) else {
                throw NSError(domain: "LibraryReconnect", code: 1, userInfo: [NSLocalizedDescriptionKey: "That folder overlaps another library source."])
            }
        }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try BookmarkStore.makeBookmark(for: url)
            resolvedRoots[source.id]?.stopAccessingSecurityScopedResource()
            sources[index].bookmark = bookmark
            sources[index].kind = .folder
            sources[index].serverID = nil
            sources[index].lastError = nil
            resolvedRoots[source.id] = url

            save()
            Logger.library.info("[reconnect] source=\(source.id.uuidString, privacy: .public) folder=\(url.lastPathComponent, privacy: .public)")
            rescan(source.id)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func restorePortable(_ old: LibraryState) {
        var restored = snapshot()
        restored.restorePortable(old)
        books = restored.books
        manualGroupings = restored.manualGroupings
        progress = restored.progress
        metadataOverrides = restored.metadataOverrides
        customArtwork = restored.customArtwork
        bookmarks = restored.bookmarks
        deletedBookmarks = restored.deletedBookmarks
        bookLists = restored.bookLists
        readingLog = restored.readingLog
        tools = restored.tools
        applyMetadataOverrides()
        save()
        onSavedPositionChanged?(Set(progress.keys))
        rescanAll(reason: "portable restore")
    }

    func applyGrouping(_ grouping: ManualGrouping, undo: Bool = false) {
        guard !isScanning else { notice = "Wait for scanning to finish."; return }
        let before = books.filter { grouping.applies(to: $0.sourceID) }
        let sourceIDs = Set(before.map(\.sourceID))
        let after = sourceIDs.flatMap { source in grouping.applied(to: before.filter { $0.sourceID == source }, source: source) }
        var revised = snapshot()
        revised.regroup(from: before.filter { !after.contains($0) }, to: after.filter { !before.contains($0) })
        progress = revised.progress; bookmarks = revised.bookmarks; metadataOverrides = revised.metadataOverrides
        customArtwork = revised.customArtwork; hiddenBookIDs = revised.hiddenBookIDs; lastBookID = revised.lastBookID
        bookLists = revised.bookLists
        manualGroupings.removeAll { $0.sourceID == grouping.sourceID }
        if !undo { manualGroupings.append(grouping) }
        books.removeAll { grouping.applies(to: $0.sourceID) }
        books.append(contentsOf: after)
        applyMetadataOverrides()
        save()
        onBooksChanged?()
        onSavedPositionChanged?(Set(after.map(\.id)))
        Logger.library.info("[grouping] arranged source=\(grouping.sourceID.uuidString, privacy: .public) books=\(after.count) undo=\(undo)")
    }

}
