import AVFoundation
import Foundation
import Observation
import UIKit
import os
import ShelfKit

/// Source of truth for the library on the main actor. Owns the security scopes of
/// every folder the user added, runs scans off-main, and persists user state.
@MainActor @Observable
final class LibraryModel {
    enum ScanStatus: Equatable {
        case idle
        case scanning(ScanProgress)
        case failed(String)
    }

    enum DuplicateScanState: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(Date)
    }

    enum NASStatus: Equatable {
        case unknown, connecting, online
        case offline(String)
    }

    /// What the player needs to play one track: a local file asset, or an SMB-streamed one.
    struct PlaybackSource {
        var asset: AVURLAsset
        var loader: SMBResourceLoader?
        var isRemote: Bool
        var serverName: String?
    }

    private(set) var sources: [LibrarySource] = []
    private(set) var books: [Book] = []
    private(set) var progress: [String: PlaybackProgress] = [:]
    private(set) var hiddenBookIDs: Set<String> = []
    private(set) var lastBookID: String?
    private(set) var scanStatus: [UUID: ScanStatus] = [:]
    private(set) var unsupportedFiles: [UUID: [String]] = [:]
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var duplicateScan: DuplicateScanState = .idle
    private(set) var hasLoaded = false
    private(set) var nasServers: [NASServer] = []
    private(set) var nasStatus: [UUID: NASStatus] = [:]
    // Cover state is changed only by LibraryModel+Covers (an extension in another file can't use
    // `private(set)`); everything else reads it.
    var customArtwork: [String: String] = [:]
    var coverChoices: [String: CoverChoice] = [:]
    @ObservationIgnored var writtenCovers: [String: String] = [:]
    /// "bookID|artworkID" cover downloads tried this launch, so a dead URL isn't retried on every scan.
    @ObservationIgnored var coverDownloadsAttempted: Set<String> = []
    private(set) var metadataOverrides: [String: BookMetadataOverride] = [:]
    private(set) var bookmarks: [String: [Bookmark]] = [:]
    private(set) var readingLog: [ReadingLogEntry] = []
    @ObservationIgnored private let cloudSync = CloudProgressSync()
    /// One-shot message for the UI (e.g. a folder was refused). Cleared by the view.
    var notice: String?

    /// Called after any scan changes `books` (the player refreshes its copy).
    @ObservationIgnored var onBooksChanged: (() -> Void)?
    /// Called with the book IDs whose saved position changed from outside the player — iCloud brought a
    /// newer one, or the book was reset — so a paused player can move there instead of saving over it.
    @ObservationIgnored var onSavedPositionChanged: ((Set<String>) -> Void)?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private var resolvedRoots: [UUID: URL] = [:]
    @ObservationIgnored private var scanTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var fingerprints: [String: FileFingerprint] = [:]
    @ObservationIgnored private var fingerprintsLoaded = false
    @ObservationIgnored private var backgroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var nasClients: [UUID: NASClient] = [:]

    var isScanning: Bool {
        scanStatus.values.contains { if case .scanning = $0 { return true } else { return false } }
    }

    init(store: LibraryStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.scanner = LibraryScanner(cache: MetadataCache(store: store), artwork: .shared)
    }

    // MARK: - Lifecycle

    func bootstrap() {
        let sw = Stopwatch()
        let state = store.loadLibrary()
        sources = state.sources
        books = state.books
        progress = state.progress
        hiddenBookIDs = state.hiddenBookIDs
        lastBookID = state.lastBookID
        nasServers = state.nasServers
        customArtwork = state.customArtwork
        coverChoices = state.coverChoices
        writtenCovers = state.writtenCovers
        metadataOverrides = state.metadataOverrides
        bookmarks = state.bookmarks
        readingLog = state.readingLog
        ensureAppDocumentsSource()
        cloudSync.onExternalChange = { [weak self] in self?.mergeCloudProgress() }
        cloudSync.start()
        mergeCloudProgress()
        for source in sources {
            resolveRoot(for: source)
        }
        hasLoaded = true
        Logger.library.info("[library] bootstrap sources=\(self.sources.count) books=\(self.books.count) progress=\(self.progress.count) in \(sw.ms, format: .fixed(precision: 1))ms")

        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        rescanAll(reason: "launch")
    }

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Path with a trailing slash so prefix checks don't match "Books" against "Books 2".
    nonisolated static func directoryPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        return path + "/"
    }

    private func ensureAppDocumentsSource() {
        guard !sources.contains(where: { $0.kind == .appDocuments }) else { return }
        let source = LibrarySource(id: UUID(), kind: .appDocuments, displayName: "On My iPhone", bookmark: nil, addedAt: .now)
        sources.insert(source, at: 0)
        Logger.library.info("[library] created app documents source")
    }

    private func resolveRoot(for source: LibrarySource) {
        switch source.kind {
        case .appDocuments:
            resolvedRoots[source.id] = Self.documentsURL
        case .smb:
            break // no local root; see `client(forServer:)`
        case .folder, .file:
            guard let data = source.bookmark else {
                setSourceError(source.id, "Missing bookmark. Remove this folder and add it again.")
                return
            }
            do {
                let resolved = try BookmarkStore.resolveAndStartAccess(data)
                resolvedRoots[source.id] = resolved.url
                if let index = sourceIndex(source.id) {
                    sources[index].lastError = nil
                    if resolved.isStale, let fresh = try? BookmarkStore.makeBookmark(for: resolved.url) {
                        sources[index].bookmark = fresh
                        scheduleSave()
                    }
                }
            } catch {
                Logger.bookmarks.error("[bookmark] resolve failed for \(source.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                setSourceError(source.id, "This folder isn't reachable anymore. Remove it and add it again.")
            }
        }
    }

    private func setSourceError(_ id: UUID, _ message: String) {
        if let index = sourceIndex(id) { sources[index].lastError = message }
        scanStatus[id] = .failed(message)
    }

    private func sourceIndex(_ id: UUID) -> Int? {
        sources.firstIndex { $0.id == id }
    }

    // MARK: - URLs

    func rootURL(for sourceID: UUID) -> URL? { resolvedRoots[sourceID] }

    func url(forBook book: Book) -> URL? {
        guard let root = resolvedRoots[book.sourceID], !isRemote(book) else { return nil }
        if book.kind == .singleFile, sources.first(where: { $0.id == book.sourceID })?.kind == .file {
            return root
        }
        return root.appending(path: book.relativePath)
    }

    func url(forTrack track: Track, in book: Book) -> URL? {
        guard let root = resolvedRoots[book.sourceID], !isRemote(book) else { return nil }
        if sources.first(where: { $0.id == book.sourceID })?.kind == .file {
            return root
        }
        return root.appending(path: track.relativePath)
    }

    func sourceName(for id: UUID) -> String {
        sources.first { $0.id == id }?.displayName ?? "Unknown"
    }

    func source(for book: Book) -> LibrarySource? {
        sources.first { $0.id == book.sourceID }
    }

    // MARK: - Sources

    func addFolders(_ urls: [URL]) {
        for url in urls {
            addSource(url: url, kind: .folder)
        }
    }

    func addOpenedFile(_ url: URL) {
        addSource(url: url, kind: .file)
    }

    private func addSource(url: URL, kind: LibrarySource.Kind) {
        let standardized = url.standardizedFileURL
        if let existing = sources.first(where: { resolvedRoots[$0.id]?.standardizedFileURL == standardized }) {
            Logger.library.notice("[library] \(url.lastPathComponent, privacy: .public) already added — rescanning")
            notice = "\(url.lastPathComponent) is already in your library. Rescanning it."
            rescan(existing.id)
            return
        }
        // A folder nested inside (or enclosing) an existing one would list the same files twice
        // and make them look like duplicates of themselves.
        let newPath = Self.directoryPath(standardized)
        for source in sources {
            guard let root = resolvedRoots[source.id] else { continue }
            let existingPath = Self.directoryPath(root.standardizedFileURL)
            if newPath.hasPrefix(existingPath) {
                Logger.library.notice("[library] refused \(url.lastPathComponent, privacy: .public): inside existing source \(source.displayName, privacy: .public)")
                notice = "\(url.lastPathComponent) is already covered by \(source.kind == .appDocuments ? "On My iPhone › Earmark" : source.displayName), so it wasn't added again."
                return
            }
            if existingPath.hasPrefix(newPath), source.isRemovable {
                Logger.library.notice("[library] \(url.lastPathComponent, privacy: .public) encloses \(source.displayName, privacy: .public) — replacing the smaller source")
                notice = "\(url.lastPathComponent) contains \(source.displayName), which was replaced by the larger folder."
                removeSource(source.id)
            }
        }
        let started = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try BookmarkStore.makeBookmark(for: url)
            let source = LibrarySource(id: UUID(), kind: kind, displayName: url.lastPathComponent, bookmark: bookmark, addedAt: .now)
            sources.append(source)
            resolvedRoots[source.id] = url
            Logger.library.info("[library] added source \(url.lastPathComponent, privacy: .public) kind=\(kind.rawValue, privacy: .public) scoped=\(started)")
            save()
            scan(source)
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            Logger.library.error("[library] add source failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeSource(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id }), source.isRemovable else { return }
        Logger.library.info("[library] removing source \(source.displayName, privacy: .public)")
        scanTasks[id]?.cancel()
        scanTasks[id] = nil
        if let root = resolvedRoots[id] {
            root.stopAccessingSecurityScopedResource()
        }
        resolvedRoots[id] = nil
        if let serverID = source.serverID {
            let client = nasClients.removeValue(forKey: serverID)
            Task { await client?.disconnect() }
            nasServers.removeAll { $0.id == serverID }
            nasStatus[serverID] = nil
            KeychainStore.delete(Self.keychainKey(for: serverID))
        }
        books.removeAll { $0.sourceID == id }
        sources.removeAll { $0.id == id }
        scanStatus[id] = nil
        unsupportedFiles[id] = nil
        duplicateGroups = []
        let cache = scanner.cache
        Task.detached(priority: .utility) {
            await cache.removeEntries(withPrefix: id.uuidString)
            await cache.flush()
        }
        save()
        onBooksChanged?()
    }

    // MARK: - Scanning

    func rescanAll(reason: String) {
        Logger.scan.info("[scan] rescan all (\(reason, privacy: .public)) sources=\(self.sources.count)")
        for source in sources {
            scan(source)
        }
    }

    func rescan(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        if resolvedRoots[id] == nil { resolveRoot(for: source) }
        scan(source)
    }

    private func scan(_ source: LibrarySource) {
        scanTasks[source.id]?.cancel()
        if source.kind == .smb {
            scanRemote(source)
            return
        }
        guard let root = resolvedRoots[source.id] else {
            if scanStatus[source.id] == nil || scanStatus[source.id] == .idle {
                setSourceError(source.id, "Folder unavailable.")
            }
            return
        }
        scanStatus[source.id] = .scanning(ScanProgress(phase: .enumerating, processed: 0, total: 0))
        let scanner = self.scanner
        let sourceID = source.id
        let reportProgress: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, case .scanning = self.scanStatus[sourceID] else { return }
                self.scanStatus[sourceID] = .scanning(progress)
            }
        }
        scanTasks[sourceID] = Task { [weak self] in
            do {
                let result = try await scanner.scan(source: source, root: root, progress: reportProgress)
                guard !Task.isCancelled else { return }
                self?.apply(result, for: sourceID)
            } catch is CancellationError {
                Logger.scan.info("[scan] cancelled for source \(sourceID.uuidString, privacy: .public)")
            } catch {
                Logger.scan.error("[scan] failed: \(error.localizedDescription, privacy: .public)")
                self?.scanStatus[sourceID] = .failed(error.localizedDescription)
                if let self, let index = self.sourceIndex(sourceID) {
                    self.sources[index].lastError = error.localizedDescription
                }
            }
        }
    }

    private func apply(_ result: ScanResult, for sourceID: UUID) {
        let existing = Dictionary(books.filter { $0.sourceID == sourceID }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = result.books.map { book -> Book in
            var book = book
            if let custom = customArtwork[book.id], ArtworkStore.shared.hasImage(id: custom) {
                book.artworkID = custom
            }
            if let old = existing[book.id] {
                book.addedAt = old.addedAt
                // Keep precise durations learned during playback over scan-time estimates.
                for (index, track) in old.tracks.enumerated() where book.tracks.indices.contains(index) && book.tracks[index].relativePath == track.relativePath && book.tracks[index].fileSize == track.fileSize {
                    if track.duration > 0 { book.tracks[index].duration = track.duration }
                }
            }
            return book
        }
        let added = updated.filter { existing[$0.id] == nil }.count
        let removed = existing.count - (updated.count - added)
        if sources.first(where: { $0.id == sourceID })?.kind == .appDocuments {
            // A book that was just downloaded from a NAS keeps the listening position of its remote twin.
            let remoteByPath = Dictionary(books.filter { isRemote($0) }.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
            for book in updated where existing[book.id] == nil && progress[book.id] == nil {
                if let twin = remoteByPath[book.relativePath], let twinProgress = progress[twin.id] {
                    progress[book.id] = twinProgress
                    Logger.library.info("[library] adopted progress from remote twin for \(book.title, privacy: .public)")
                }
            }
        }
        books.removeAll { $0.sourceID == sourceID }
        books.append(contentsOf: updated)
        BookGrouper.canonicalizeAuthors(&books)
        applyMetadataOverrides()
        if let index = sourceIndex(sourceID) {
            sources[index].lastScanAt = .now
            sources[index].lastScanBookCount = updated.count
            sources[index].lastScanFileCount = result.fileCount
            sources[index].lastError = nil
        }
        unsupportedFiles[sourceID] = result.unsupportedFiles
        scanStatus[sourceID] = .idle
        mergeCloudProgress()
        Logger.library.notice("[library] applied scan source=\(self.sourceName(for: sourceID), privacy: .public) books=\(updated.count) files=\(result.fileCount) added=\(added) removed=\(removed)")
        for book in updated.sorted(by: { $0.title.naturallyPrecedes($1.title) }) {
            let series = book.series.map { $0 + (book.seriesIndex.map { " #\(BookDetailView.format($0))" } ?? "") } ?? "-"
            Logger.library.notice("[library] book \"\(book.title, privacy: .public)\" by \(book.displayAuthor, privacy: .public) | series=\(series, privacy: .public) | narrator=\(book.narrator ?? "-", privacy: .public) | \(book.tracks.count) files, \(book.chapters.count) chapters, \(book.totalDuration.shortDurationString, privacy: .public) | \(book.relativePath, privacy: .public)")
        }
        save()
        onBooksChanged?()
        reconcileCovers()   // new books, or custom covers lost with the art cache
    }

    private func scanRemote(_ source: LibrarySource) {
        guard let serverID = source.serverID, let client = client(forServer: serverID) else {
            setSourceError(source.id, "This NAS isn't configured anymore. Remove it and add it again.")
            return
        }
        let sourceID = source.id
        nasStatus[serverID] = .connecting
        scanStatus[sourceID] = .scanning(ScanProgress(phase: .enumerating, processed: 0, total: 0))
        let scanner = self.scanner
        let reportProgress: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, case .scanning = self.scanStatus[sourceID] else { return }
                self.scanStatus[sourceID] = .scanning(progress)
            }
        }
        scanTasks[sourceID] = Task { [weak self] in
            do {
                try await client.ensureConnected()
                self?.nasStatus[serverID] = .online
                let result = try await scanner.scanRemote(source: source, client: client, progress: reportProgress)
                guard !Task.isCancelled else { return }
                self?.apply(result, for: sourceID)
            } catch is CancellationError {
                Logger.scan.info("[scan] remote cancelled")
            } catch {
                Logger.scan.error("[scan] remote failed: \(error.localizedDescription, privacy: .public)")
                guard let self else { return }
                self.nasStatus[serverID] = .offline(error.localizedDescription)
                self.scanStatus[sourceID] = .failed(error.localizedDescription)
                if let index = self.sourceIndex(sourceID) { self.sources[index].lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - NAS

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
        let source = LibrarySource(id: UUID(), kind: .smb, displayName: server.name, bookmark: nil, addedAt: .now, serverID: server.id)
        sources.append(source)
        save()
        scan(source)
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

    /// A downloaded copy of a remote book, matched by its path relative to the library root.
    func localTwin(of book: Book) -> Book? {
        guard isRemote(book) else { return nil }
        return books.first { candidate in
            candidate.id != book.id && candidate.relativePath == book.relativePath && source(for: candidate)?.kind == .appDocuments
        }
    }

    /// When a download is removed, the NAS copy picks up where it left off: the newer place, the
    /// bookmarks, a picked cover or corrected details it lacks, hidden, "last played".
    func returnDownloadState(from localID: String, to remoteID: String) {
        progress[remoteID] = DownloadRemoval.place(from: progress[localID], onto: progress[remoteID])
        if let marks = bookmarks[localID] { bookmarks[remoteID] = DownloadRemoval.bookmarks(from: marks, onto: bookmarks[remoteID] ?? []) }
        if metadataOverrides[remoteID] == nil, let override = metadataOverrides[localID] { metadataOverrides[remoteID] = override }
        if let art = customArtwork.removeValue(forKey: localID) {
            if customArtwork[remoteID] == nil { customArtwork[remoteID] = art; setArtworkID(art, forBook: remoteID) } else { ArtworkStore.shared.remove(id: art) }
        }
        if hiddenBookIDs.remove(localID) != nil { hiddenBookIDs.insert(remoteID) }
        if lastBookID == localID { lastBookID = remoteID }
        progress[localID] = nil
        bookmarks[localID] = nil
        metadataOverrides[localID] = nil
        writtenCovers[localID] = nil
        ArtworkStore.shared.remove(id: ArtworkStore.shared.id(for: localID))
        applyMetadataOverrides()
        save()
    }

    // MARK: - Progress

    func progress(for bookID: String) -> PlaybackProgress {
        progress[bookID] ?? PlaybackProgress()
    }

    func recordPosition(bookID: String, trackIndex: Int, time: TimeInterval) {
        var entry = progress[bookID] ?? PlaybackProgress()
        if entry.isUnchanged(trackIndex: trackIndex, time: time) {
            lastBookID = bookID
            return
        }
        entry.trackIndex = trackIndex
        entry.time = time
        entry.lastPlayedAt = .now
        entry.modifiedAt = .now
        if entry.startedAt == nil { entry.startedAt = .now }
        entry.isFinished = false
        progress[bookID] = entry
        lastBookID = bookID
        scheduleSave()
    }

    /// The always-present "On My iPhone › Earmark" source.
    var appDocumentsSource: LibrarySource? {
        sources.first { $0.kind == .appDocuments }
    }

    /// Carry listening position from a book that was moved/downloaded to its new local identity.
    func adoptProgress(from oldBookID: String, to newBookID: String) {
        guard let entry = progress[oldBookID] else { return }
        if progress[newBookID] == nil {
            progress[newBookID] = entry
            if lastBookID == oldBookID { lastBookID = newBookID }
            Logger.library.info("[library] adopted progress → \(newBookID, privacy: .public)")
            scheduleSave()
        }
    }

    func setCurrentBook(_ bookID: String) {
        lastBookID = bookID
        scheduleSave()
    }

    func setSpeed(_ speed: Float, for bookID: String) {
        var entry = progress[bookID] ?? PlaybackProgress()
        entry.speed = speed
        entry.modifiedAt = .now
        progress[bookID] = entry
        scheduleSave()
    }

    func markFinished(_ bookID: String, on date: Date? = nil) {
        var entry = progress[bookID] ?? PlaybackProgress()
        entry.isFinished = true
        entry.finishedAt = date ?? .now
        entry.lastPlayedAt = entry.lastPlayedAt ?? (date ?? .now)
        entry.modifiedAt = .now
        if let book = book(id: bookID), let last = book.tracks.last {
            entry.trackIndex = book.tracks.count - 1
            entry.time = last.duration
        }
        progress[bookID] = entry
        Logger.library.info("[library] marked finished \(bookID, privacy: .public) on \(entry.finishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "now", privacy: .public)")
        scheduleSave()
    }

    /// Backdates (or changes) when a finished book was completed, for accurate per-year stats.
    func setFinishedDate(_ bookID: String, _ date: Date) {
        var entry = progress[bookID] ?? PlaybackProgress()
        entry.isFinished = true
        entry.finishedAt = date
        entry.modifiedAt = .now
        progress[bookID] = entry
        scheduleSave()
    }

    /// The listener's star rating (1–5, or nil to clear) for a library book.
    func setRating(_ bookID: String, _ rating: Int?) {
        var entry = progress[bookID] ?? PlaybackProgress()
        entry.rating = rating.map { min(5, max(1, $0)) }
        entry.modifiedAt = .now
        progress[bookID] = entry
        scheduleSave()
    }

    // MARK: - Reading log (books finished outside the app)

    @discardableResult
    func addReadingLogEntry(title: String, author: String?, finishedAt: Date, rating: Int? = nil, hours: Double? = nil) -> ReadingLogEntry {
        let entry = ReadingLogEntry(title: title, author: author?.isEmpty == true ? nil : author, finishedAt: finishedAt,
                                    rating: rating.map { min(5, max(1, $0)) }, hours: hours)
        readingLog.append(entry)
        Logger.library.info("[library] logged past book \(title, privacy: .public)")
        scheduleSave()
        return entry
    }

    func updateReadingLogEntry(_ entry: ReadingLogEntry) {
        guard let index = readingLog.firstIndex(where: { $0.id == entry.id }) else { return }
        readingLog[index] = entry
        scheduleSave()
    }

    func removeReadingLogEntry(_ id: String) {
        readingLog.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Aggregated history for the Stats tab: finished library books plus hand-logged past books.
    var readingStats: ReadingStats {
        var items: [ReadingStatsBuilder.Item] = []
        for book in visibleBooks {
            guard let entry = progress[book.id], entry.isFinished else { continue }
            let when = entry.finishedAt ?? entry.lastPlayedAt ?? book.addedAt
            items.append(.init(finishedAt: when, hours: book.totalDuration / 3600, rating: entry.rating, author: book.author))
        }
        for entry in readingLog {
            items.append(.init(finishedAt: entry.finishedAt, hours: entry.hours ?? 0, rating: entry.rating, author: entry.author))
        }
        return ReadingStatsBuilder.build(items)
    }

    func resetProgress(_ bookID: String) {
        // Kept as a dated, not-started entry rather than removed: with nothing to compare, the next
        // iCloud merge brought the old position straight back.
        var fresh = PlaybackProgress(speed: progress[bookID]?.speed)
        fresh.modifiedAt = .now
        progress[bookID] = fresh
        Logger.library.info("[library] reset progress \(bookID, privacy: .public)")
        scheduleSave()
        onSavedPositionChanged?([bookID])
    }

    func setHidden(_ hidden: Bool, bookID: String) {
        if hidden { hiddenBookIDs.insert(bookID) } else { hiddenBookIDs.remove(bookID) }
        scheduleSave()
    }

    func updateTrackDuration(bookID: String, trackIndex: Int, duration: TimeInterval) {
        guard let index = books.firstIndex(where: { $0.id == bookID }), books[index].tracks.indices.contains(trackIndex) else { return }
        let old = books[index].tracks[trackIndex].duration
        guard abs(old - duration) > 0.5 else { return }
        books[index].tracks[trackIndex].duration = duration
        let chaptersInTrack = books[index].chapters.indices.filter { books[index].chapters[$0].trackIndex == trackIndex }
        if chaptersInTrack.count == 1, let only = chaptersInTrack.first, books[index].chapters[only].start == 0 {
            books[index].chapters[only].duration = duration
        }
        Logger.library.debug("[library] precise duration track=\(trackIndex) \(old, format: .fixed(precision: 1)) → \(duration, format: .fixed(precision: 1))")
        scheduleSave()
    }

    // MARK: - Persistence

    func save() { persist(pushCloud: true) }

    private func persist(pushCloud: Bool) {
        saveTask?.cancel()
        saveTask = nil
        let state = LibraryState(sources: sources, books: books, progress: progress, hiddenBookIDs: hiddenBookIDs, lastBookID: lastBookID, nasServers: nasServers, customArtwork: customArtwork, coverChoices: coverChoices, writtenCovers: writtenCovers, metadataOverrides: metadataOverrides, bookmarks: bookmarks, readingLog: readingLog)
        let store = self.store
        Task.detached(priority: .utility) {
            do {
                try store.saveLibrary(state)
            } catch {
                Logger.store.error("[store] save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if pushCloud {
            let snapshot = ProgressSync.cloudSnapshot(local: progress, books: books, existingCloud: cloudSync.load())
            cloudSync.save(snapshot)
            cloudSync.saveReadingLog(mergedReadingLog(with: cloudSync.loadReadingLog()))
            cloudSync.saveCoverChoices(CoverSync.merged(local: coverChoices, cloud: cloudSync.loadCoverChoices()))
        }
    }

    /// Union of local and cloud reading-log entries by id (local wins on conflict).
    private func mergedReadingLog(with cloud: [ReadingLogEntry]) -> [ReadingLogEntry] {
        var byID = Dictionary(readingLog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for entry in cloud where byID[entry.id] == nil { byID[entry.id] = entry }
        return byID.values.sorted { $0.finishedAt > $1.finishedAt }
    }

    /// Folds any newer progress from other devices into the local library.
    private func mergeCloudProgress() {
        let merged = ProgressSync.merged(local: progress, books: books, cloud: cloudSync.load())
        let mergedLog = mergedReadingLog(with: cloudSync.loadReadingLog())
        let mergedCovers = CoverSync.merged(local: coverChoices, cloud: cloudSync.loadCoverChoices())
        let logChanged = mergedLog.count != readingLog.count
        // Compare values, not counts: a replaced cover keeps its key and changes only the choice.
        let coversChanged = mergedCovers != coverChoices
        let progressChanged = merged != progress
        guard progressChanged || logChanged || coversChanged else { return }
        let moved = Set(merged.keys.filter { id in
            guard let new = merged[id] else { return false }
            guard let old = progress[id] else { return true }
            return new.trackIndex != old.trackIndex || new.time != old.time
        })
        progress = merged
        if logChanged { readingLog = mergedLog }
        if coversChanged { coverChoices = mergedCovers }
        Logger.library.info("[library] merged from iCloud progress=\(progressChanged) log=\(logChanged) covers=\(coversChanged)")
        persist(pushCloud: false)   // write locally; don't echo the merge straight back
        onBooksChanged?()
        if !moved.isEmpty { onSavedPositionChanged?(moved) }
        if coversChanged { reconcileCovers() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // MARK: - Duplicates

    private struct FingerprintTarget: Sendable {
        var key: String
        var url: URL
        var size: Int64
    }

    func findDuplicates() {
        if case .running = duplicateScan { return }
        if !fingerprintsLoaded {
            fingerprints = store.loadJSON([String: FileFingerprint].self, named: LibraryStore.fingerprintsFile) ?? [:]
            fingerprintsLoaded = true
        }
        let targets: [FingerprintTarget] = visibleBooks.flatMap { book in
            book.tracks.compactMap { track -> FingerprintTarget? in
                guard let url = url(forTrack: track, in: book) else { return nil }
                return FingerprintTarget(key: DuplicateFinder.trackKey(book.sourceID, track.relativePath), url: url, size: track.fileSize)
            }
        }
        let known = fingerprints
        let total = targets.count
        duplicateScan = .running(done: 0, total: total)
        Logger.duplicates.info("[duplicates] start files=\(total) cached=\(known.count)")
        let sw = Stopwatch()

        Task { [weak self] in
            let computed: [String: FileFingerprint] = await Task.detached(priority: .userInitiated) {
                var out: [String: FileFingerprint] = [:]
                for (index, target) in targets.enumerated() {
                    if let cached = known[target.key], cached.size == target.size {
                        out[target.key] = cached
                    } else {
                        do {
                            out[target.key] = try DuplicateFinder.fingerprint(url: target.url)
                        } catch {
                            Logger.duplicates.error("[duplicates] fingerprint failed \(target.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    if index % 25 == 0 {
                        let done = index + 1
                        Task { @MainActor [weak self] in self?.duplicateScan = .running(done: done, total: total) }
                    }
                }
                return out
            }.value
            guard let self else { return }
            self.fingerprints = computed
            let store = self.store
            Task.detached(priority: .utility) {
                try? store.saveJSON(computed, named: LibraryStore.fingerprintsFile)
            }
            self.duplicateGroups = DuplicateFinder.duplicateGroups(books: self.visibleBooks, fingerprints: computed)
            self.duplicateScan = .finished(.now)
            Logger.duplicates.info("[duplicates] done groups=\(self.duplicateGroups.count) in \(sw.ms, format: .fixed(precision: 0))ms")
        }
    }

    /// Permanently deletes files from disk. Returns human-readable errors, if any.
    func deleteFiles(_ files: [DuplicateFile]) -> [String] {
        var errors: [String] = []
        var touchedSources: Set<UUID> = []
        for file in files {
            guard let root = resolvedRoots[file.sourceID] else {
                errors.append("\(file.relativePath): folder unavailable")
                continue
            }
            let url = root.appending(path: file.relativePath)
            do {
                try FileManager.default.removeItem(at: url)
                touchedSources.insert(file.sourceID)
                Logger.duplicates.notice("[duplicates] deleted \(file.relativePath, privacy: .public)")
            } catch {
                errors.append("\(file.relativePath): \(error.localizedDescription)")
                Logger.duplicates.error("[duplicates] delete failed \(file.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        duplicateGroups = []
        duplicateScan = .idle
        for id in touchedSources { rescan(id) }
        return errors
    }

    func deleteBookFiles(_ book: Book) -> [String] {
        let files = book.tracks.map {
            DuplicateFile(bookID: book.id, bookTitle: book.title, sourceID: book.sourceID, relativePath: $0.relativePath, size: $0.fileSize)
        }
        let errors = deleteFiles(files)
        if errors.isEmpty, book.kind == .folder, let folder = url(forBook: book) {
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if leftovers.allSatisfy({ AudioFileTypes.images.contains(($0 as NSString).pathExtension.lowercased()) || $0.hasPrefix(".") }) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        return errors
    }

    /// The one way cover code (LibraryModel+Covers) changes a book: which artwork it shows.
    func setArtworkID(_ id: String?, forBook bookID: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].artworkID = id
    }

    // MARK: - Metadata corrections

    /// Overlays the user's saved corrections onto every book in place. Called after each scan so
    /// corrections win over detection but never fight the metadata cache.
    private func applyMetadataOverrides() {
        guard !metadataOverrides.isEmpty else { return }
        for index in books.indices {
            if let override = metadataOverrides[books[index].id] {
                books[index] = override.applied(to: books[index])
            }
        }
    }

    /// Records a correction (only the fields that changed) and applies it immediately.
    func setMetadataOverride(_ diff: BookMetadataOverride, for book: Book) {
        guard !diff.isEmpty else { return }
        let merged = (metadataOverrides[book.id] ?? BookMetadataOverride()).merged(with: diff)
        metadataOverrides[book.id] = merged.isEmpty ? nil : merged
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = diff.applied(to: books[index])
            BookGrouper.canonicalizeAuthors(&books)
        }
        Logger.library.info("[library] metadata corrected for \(book.title, privacy: .public)")
        save()
        onBooksChanged?()
    }

    /// Drops all corrections for a book and rescans its source so detected values come back.
    func resetMetadataOverride(for book: Book) {
        guard metadataOverrides[book.id] != nil else { return }
        metadataOverrides[book.id] = nil
        save()
        rescan(book.sourceID)
    }

    /// The corrections currently stored for a book (for pre-filling the edit form).
    func metadataOverride(for book: Book) -> BookMetadataOverride? { metadataOverrides[book.id] }

    // MARK: - Bookmarks

    func bookmarks(for book: Book) -> [Bookmark] { bookmarks[book.id] ?? [] }

    @discardableResult
    func addBookmark(for book: Book, offset: TimeInterval, note: String = "") -> Bookmark {
        var list = bookmarks[book.id] ?? []
        let mark = Bookmark(offset: max(0, offset), note: note)
        list.append(mark)
        bookmarks[book.id] = list.sorted { $0.offset < $1.offset }
        Logger.library.info("[library] bookmark added for \(book.title, privacy: .public) at \(Int(offset))s")
        save()
        onBooksChanged?()
        return mark
    }

    func updateBookmark(_ id: String, for book: Book, note: String) {
        guard var list = bookmarks[book.id], let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].note = note
        bookmarks[book.id] = list
        save()
        onBooksChanged?()
    }

    func removeBookmark(_ id: String, for book: Book) {
        guard var list = bookmarks[book.id] else { return }
        list.removeAll { $0.id == id }
        bookmarks[book.id] = list.isEmpty ? nil : list
        save()
        onBooksChanged?()
    }

    // MARK: - Import reading history

    private struct HistoryItem: Decodable {
        var title: String
        var author: String?
        var year: Int
        var month: Int?
        var rating: Int?
        var hours: Double?
    }

    private static func normTitle(_ t: String) -> String {
        String(t.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Imports a reading history (e.g. parsed from a blog): backdates matching library books as
    /// finished with their rating, and logs the rest as past books. Skips anything already recorded.
    /// Returns (books backdated, past books logged).
    @discardableResult
    func importReadingHistory(_ data: Data) -> (matched: Int, logged: Int) {
        guard let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return (0, 0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let libraryByTitle = Dictionary(books.map { (Self.normTitle($0.title), $0) }, uniquingKeysWith: { a, _ in a })
        var loggedTitles = Set(readingLog.map { Self.normTitle($0.title) })
        var matched = 0, logged = 0
        for item in items {
            let key = Self.normTitle(item.title)
            guard !key.isEmpty else { continue }
            let date = calendar.date(from: DateComponents(year: item.year, month: item.month ?? 6, day: 15)) ?? .now
            if let book = libraryByTitle[key] ?? books.first(where: { let n = Self.normTitle($0.title); return !n.isEmpty && (n.hasPrefix(key) || key.hasPrefix(n)) }) {
                if progress[book.id]?.isFinished != true {
                    markFinished(book.id, on: date)
                    matched += 1
                }
                if let rating = item.rating, progress[book.id]?.rating == nil { setRating(book.id, rating) }
            } else if !loggedTitles.contains(key) {
                addReadingLogEntry(title: item.title, author: item.author, finishedAt: date, rating: item.rating, hours: item.hours)
                loggedTitles.insert(key)
                logged += 1
            }
        }
        Logger.library.info("[library] imported reading history: matched=\(matched) logged=\(logged)")
        return (matched, logged)
    }

    // MARK: - Files app

    func revealInFiles(_ book: Book) {
        guard let url = url(forBook: book) else { return }
        let target = "shareddocuments://" + url.path(percentEncoded: true)
        guard let filesURL = URL(string: target) else { return }
        Logger.ui.info("[ui] reveal in Files \(book.title, privacy: .public)")
        UIApplication.shared.open(filesURL)
    }
}
