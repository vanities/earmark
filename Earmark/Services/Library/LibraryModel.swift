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

    private(set) var sources: [LibrarySource] = []
    private(set) var books: [Book] = []
    private(set) var progress: [String: PlaybackProgress] = [:]
    private(set) var hiddenBookIDs: Set<String> = []
    private(set) var lastBookID: String?
    private(set) var scanStatus: [UUID: ScanStatus] = [:]
    private(set) var unsupportedFiles: [UUID: [String]] = [:]
    // Duplicate state is changed only by LibraryModel+Duplicates (and `removeSource`), NAS state
    // only by LibraryModel+NAS — an extension in another file can't use `private(set)`.
    var duplicateGroups: [DuplicateGroup] = []
    var duplicateScan: DuplicateScanState = .idle
    private(set) var hasLoaded = false
    var nasServers: [NASServer] = []
    var nasStatus: [UUID: NASStatus] = [:]
    // Cover state is changed only by LibraryModel+Covers (an extension in another file can't use
    // `private(set)`); everything else reads it.
    var customArtwork: [String: String] = [:]
    var coverChoices: [String: CoverChoice] = [:]
    @ObservationIgnored var writtenCovers: [String: String] = [:]
    /// "bookID|artworkID" cover downloads tried this launch, so a dead URL isn't retried on every scan.
    @ObservationIgnored var coverDownloadsAttempted: Set<String> = []
    private(set) var metadataOverrides: [String: BookMetadataOverride] = [:]
    private(set) var bookmarks: [String: [Bookmark]] = [:]
    @ObservationIgnored private(set) var deletedBookmarks = Tombstones()
    /// NAS books whose download just finished, until the scan that finds the download (`noteDownloaded`).
    @ObservationIgnored private var justDownloaded: Set<String> = []
    /// The user's own lists (LibraryModel+Lists).
    var bookLists: [BookList] = []
    /// Books finished outside the app: changed only by LibraryModel+History and the iCloud merge.
    var readingLog: [ReadingLogEntry] = []
    /// This device's listening sessions: changed only by LibraryModel+Activity.
    var sessions: [ListeningSession] = []
    @ObservationIgnored let cloudSync = CloudProgressSync()
    /// One-shot message for the UI (e.g. a folder was refused). Cleared by the view.
    var notice: String?

    /// Called after any scan changes `books` (the player refreshes its copy).
    @ObservationIgnored var onBooksChanged: (() -> Void)?
    /// Called with the book IDs whose saved position changed from outside the player — iCloud brought a
    /// newer one, or the book was reset — so a paused player can move there instead of saving over it.
    @ObservationIgnored var onSavedPositionChanged: ((Set<String>) -> Void)?

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private var resolvedRoots: [UUID: URL] = [:]
    @ObservationIgnored private var scanTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// LibraryModel+Duplicates' cache of file fingerprints, loaded on first use.
    @ObservationIgnored var fingerprints: [String: FileFingerprint] = [:]
    @ObservationIgnored var fingerprintsLoaded = false
    @ObservationIgnored private var backgroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored var nasClients: [UUID: NASClient] = [:]

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
        deletedBookmarks = state.deletedBookmarks
        bookLists = state.bookLists
        readingLog = state.readingLog
        sessions = state.sessions
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
        recoverInterruptedListening()
        rescanAll(reason: "launch")
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

    /// A NAS share joins the library like any folder (see `addNAS` in LibraryModel+NAS).
    func addRemoteSource(_ source: LibrarySource) {
        sources.append(source)
        save()
        scan(source)
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
        let reportProgress = progressReporter(for: sourceID)
        scanTasks[sourceID] = Task { [weak self] in
            do {
                let result = try await scanner.scan(source: source, root: root, progress: reportProgress)
                guard !Task.isCancelled else { return }
                self?.apply(result, for: sourceID)
            } catch is CancellationError {
                Logger.scan.info("[scan] cancelled for source \(sourceID.uuidString, privacy: .public)")
            } catch {
                Logger.scan.error("[scan] failed: \(error.localizedDescription, privacy: .public)")
                self?.setSourceError(sourceID, error.localizedDescription)
            }
        }
    }

    /// Reports a scan's progress until that scan has finished or failed.
    private func progressReporter(for sourceID: UUID) -> @Sendable (ScanProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, case .scanning = self.scanStatus[sourceID] else { return }
                self.scanStatus[sourceID] = .scanning(progress)
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
            adoptStateFromRemoteTwins(of: updated.filter { existing[$0.id] == nil })
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
        let reportProgress = progressReporter(for: sourceID)
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
                self.setSourceError(sourceID, error.localizedDescription)
            }
        }
    }

    // MARK: - Copies of a book

    /// The per-book state that follows a book between its copies (`CopyState`), read and written
    /// together; only what changed is written back, so nothing else redraws.
    private var copyState: CopyState {
        get { CopyState(progress: progress, bookmarks: bookmarks, corrections: metadataOverrides, hidden: hiddenBookIDs, lastBookID: lastBookID) }
        set {
            if newValue.progress != progress { progress = newValue.progress }
            if newValue.bookmarks != bookmarks { bookmarks = newValue.bookmarks }
            if newValue.corrections != metadataOverrides { metadataOverrides = newValue.corrections }
            if newValue.hidden != hiddenBookIDs { hiddenBookIDs = newValue.hidden }
            if newValue.lastBookID != lastBookID { lastBookID = newValue.lastBookID }
        }
    }

    /// One copy of a book leaves the library and another stays — a download is removed (the NAS
    /// copy stays), or a book moves into Earmark's folder (the moved copy stays). Everything done
    /// to the leaving copy goes to the staying one (`CopyState.handOver`), and its picked cover.
    /// `filesMoved`: the leaving copy's files went too, so a cover image Earmark wrote beside them
    /// is still Earmark's to replace.
    func handOverState(from oldID: String, to newID: String, filesMoved: Bool = false) {
        var state = copyState
        state.handOver(from: oldID, to: newID)
        copyState = state
        if let art = customArtwork.removeValue(forKey: oldID) {
            if customArtwork[newID] == nil { customArtwork[newID] = art; setArtworkID(art, forBook: newID) } else { ArtworkStore.shared.remove(id: art) }
        }
        if filesMoved, writtenCovers[newID] == nil, let written = writtenCovers[oldID] { writtenCovers[newID] = written }
        writtenCovers[oldID] = nil
        ArtworkStore.shared.remove(id: ArtworkStore.shared.id(for: oldID))
        applyMetadataOverrides()
        Logger.library.info("[library] state handed over \(oldID, privacy: .public) → \(newID, privacy: .public)\(filesMoved ? " with its files" : "", privacy: .public)")
        save()
    }

    /// A download finished: the scan that finds it knows which NAS book it came from.
    func noteDownloaded(_ remoteID: String) { justDownloaded.insert(remoteID) }

    /// Books that just arrived in Earmark's folder from a NAS take what was done to their NAS copy
    /// and they don't have yet (`CopyState.adopt`): the place, bookmarks, corrections, hidden.
    private func adoptStateFromRemoteTwins(of arrivals: [Book]) {
        guard !arrivals.isEmpty else { return }
        var state = copyState
        var adopted: [String] = []
        for (arrival, twin) in CopyState.remoteTwins(of: arrivals, among: books.filter { isRemote($0) }, downloaded: justDownloaded) {
            justDownloaded.remove(twin.id)
            if state.adopt(into: arrival.id, from: twin.id) { adopted.append(arrival.title) }
        }
        guard !adopted.isEmpty else { return }
        copyState = state
        Logger.library.info("[library] carried over from the NAS copy: \(adopted.joined(separator: ", "), privacy: .public)")
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
        var state = LibraryState(sources: sources, books: books, progress: progress, hiddenBookIDs: hiddenBookIDs, lastBookID: lastBookID, nasServers: nasServers, customArtwork: customArtwork, coverChoices: coverChoices, writtenCovers: writtenCovers, metadataOverrides: metadataOverrides, bookmarks: bookmarks, readingLog: readingLog)
        state.deletedBookmarks = deletedBookmarks
        state.bookLists = bookLists
        state.sessions = sessions
        let store = self.store
        Task.detached(priority: .utility) {
            do {
                try store.saveLibrary(state)
            } catch {
                Logger.store.error("[store] save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if pushCloud { pushToCloud() }
    }

    /// Folds any newer progress from other devices into the local library.
    private func mergeCloudProgress() {
        let merged = ProgressSync.merged(local: progress, books: books, cloud: cloudSync.load())
        let mergedLog = mergedReadingLog(with: cloudSync.loadReadingLog())
        let mergedCovers = CoverSync.merged(local: coverChoices, cloud: cloudSync.loadCoverChoices())
        let buried = allDeletedBookmarks()
        let mergedMarks = BookmarkSync.merged(local: bookmarks, books: books, cloud: cloudSync.loadBookmarks(), buried: buried)
        let marksChanged = mergedMarks != bookmarks || buried != deletedBookmarks
        let logChanged = mergedLog.count != readingLog.count
        // Compare values, not counts: a replaced cover keeps its key and changes only the choice.
        let coversChanged = mergedCovers != coverChoices
        let progressChanged = merged != progress
        guard progressChanged || logChanged || coversChanged || marksChanged else { return }
        let moved = Set(merged.keys.filter { id in
            guard let new = merged[id] else { return false }
            guard let old = progress[id] else { return true }
            return new.trackIndex != old.trackIndex || new.time != old.time
        })
        progress = merged
        if logChanged { readingLog = mergedLog }
        if coversChanged { coverChoices = mergedCovers }
        if marksChanged { (bookmarks, deletedBookmarks) = (mergedMarks, buried) }
        Logger.library.info("[library] merged from iCloud progress=\(progressChanged) log=\(logChanged) covers=\(coversChanged) bookmarks=\(marksChanged)")
        persist(pushCloud: false)   // write locally; don't echo the merge straight back
        onBooksChanged?()
        if !moved.isEmpty { onSavedPositionChanged?(moved) }
        if coversChanged { reconcileCovers() }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.save()
        }
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
        deletedBookmarks.bury(id)   // or iCloud's copy brings it back on the next merge
        save()
        onBooksChanged?()
    }
}
