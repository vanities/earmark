import Foundation
import os
import ShelfKit

// MARK: - Books arriving while Earmark is open
//
// Besides Add Folder, books reach the shelf by being dropped into Earmark's folder from the Files
// app (beside Earmark on an iPad, or while it waits in the background), by "Open With Earmark" or
// a share sheet, or by being added to a folder picked earlier. The launch scan used to be the only
// look at any of them, so a book dropped in while Earmark was open stayed off the shelf until a
// relaunch, and App Review saw an empty shelf after adding files.

extension LibraryModel {
    /// Where a book being opened is expected to turn up: that source's next scan plays it.
    struct PendingOpen {
        let sourceID: UUID
        /// Inside a folder source, the opened file's path; nil for a file opened on its own.
        let relativePath: String?
        let at: Date
    }

    /// A local source is looked at again on coming back only if its last scan is older than this;
    /// app switches, Control Center and the lock screen all come back through "active".
    static let foregroundRescanInterval: TimeInterval = 10

    /// How long an opened file may take to reach the shelf and still be played. A slower scan
    /// (or a failed one retried later) doesn't start playing out of the blue.
    static let openedFileWindow: TimeInterval = 60

    // MARK: Coming back

    /// Earmark came back to the front: look again at the local sources (not a NAS, which is walked
    /// over the network and has its own Sync), unless one is mid-scan or was read a moment ago.
    func sceneBecameActive() {
        let now = Date()
        let due = sources.filter { source in
            guard source.kind != .smb, !isScanning(source.id) else { return false }
            guard let last = source.lastScanAt else { return true }
            return now.timeIntervalSince(last) > Self.foregroundRescanInterval
        }
        guard !due.isEmpty else { return }
        Logger.scan.info("[scan] back in front — rescanning \(due.count) local source(s)")
        for source in due { rescan(source.id) }
    }

    private func isScanning(_ sourceID: UUID) -> Bool {
        if case .scanning = scanStatus[sourceID] { return true }
        return false
    }

    // MARK: Earmark's own folder

    /// Watches Earmark's folder for as long as the app runs. Only its top level reports changes
    /// (a new book's folder or file); something added deeper down is found on coming back.
    func watchOwnFolder() {
        guard ownFolderWatcher == nil else { return }
        ownFolderWatcher = FolderWatcher(url: Self.documentsURL) { [weak self] in
            self?.ownFolderChanged()
        }
    }

    private func ownFolderChanged() {
        guard let own = appDocumentsSource else { return }
        Logger.scan.info("[scan] Earmark's folder changed — rescanning it")
        rescan(own.id)
    }

    // MARK: Opened files

    /// "Open With Earmark" or a share sheet handed Earmark an audio file: put it on the shelf and,
    /// once it's there, play it (`openedBook`, which the root view picks up).
    func addOpenedFile(_ url: URL) {
        let documents = Self.documentsURL
        // Shared from another app, the file arrives as Earmark's own copy in its Inbox, iOS's
        // folder, which isn't a place to keep it. It moves up into Earmark's folder, where it's
        // an ordinary book.
        if url.relativePath(inside: documents) != nil {
            let kept = OpenedFiles.isInInbox(url, documents: documents) ? OpenedFiles.moveOutOfInbox(url, into: documents) : url
            guard let own = appDocumentsSource else { return }
            expectOpen(own.id, relativePath: kept.relativePath(inside: documents))
            rescan(own.id)
            return
        }
        // Already on the shelf through a folder (or the same file) added earlier: look at it again.
        for source in sources where source.kind != .smb {
            guard let root = rootURL(for: source.id) else { continue }
            if source.kind == .file, root.isSameFile(as: url) {
                expectOpen(source.id, relativePath: nil)
                rescan(source.id)
                return
            }
            if source.kind != .file, let path = url.relativePath(inside: root) {
                expectOpen(source.id, relativePath: path)
                rescan(source.id)
                return
            }
        }
        if let id = addSource(url: url, kind: .file) {
            expectOpen(id, relativePath: nil)
        }
    }

    private func expectOpen(_ sourceID: UUID, relativePath: String?) {
        Logger.library.info("[library] opening \(relativePath ?? "a file", privacy: .public) from source \(sourceID.uuidString, privacy: .public)")
        pendingOpen = PendingOpen(sourceID: sourceID, relativePath: relativePath, at: .now)
    }

    /// A source's scan landed: if it holds the file just opened, that book is the one to play.
    func resolvePendingOpen(in sourceID: UUID, books arrived: [Book]) {
        guard let pending = pendingOpen, pending.sourceID == sourceID else { return }
        pendingOpen = nil
        guard Date().timeIntervalSince(pending.at) < Self.openedFileWindow else {
            Logger.library.notice("[library] opened file took too long to scan; not playing it now")
            return
        }
        let book = if let path = pending.relativePath {
            arrived.first { $0.relativePath == path || $0.tracks.contains { $0.relativePath == path } }
        } else {
            arrived.first
        }
        guard let book else {
            Logger.library.notice("[library] opened file \(pending.relativePath ?? "-", privacy: .public) isn't a book on the shelf")
            return
        }
        Logger.library.info("[library] opened \(book.title, privacy: .public) — playing it")
        openedBookAt = .now
        openedBook = book
    }
}

@MainActor
extension DeviceStorage {
    /// Earmark's folder in Files: "On My iPhone › Earmark", or "On My iPad › Earmark".
    static var earmarkFolder: String { folder("Earmark") }
}
