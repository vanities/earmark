import BackgroundTasks
import Foundation
import Observation
import UIKit
import os
import ShelfKit

/// Copies remote books into "On My iPhone › Earmark", one at a time, keeping the same
/// relative folder layout so the local copy groups exactly like the remote one did.
@MainActor @Observable
final class DownloadManager {
    struct Job: Identifiable, Equatable, Codable {
        enum State: String, Equatable, Codable { case queued, running, done, failed, cancelled }
        enum Kind: String, Equatable, Codable { case download, move, mirror }
        let id: UUID
        let bookID: String
        let title: String
        var kind: Kind = .download
        var serverID: UUID?
        var totalBytes: Int64
        var doneBytes: Int64 = 0
        var state: State = .queued
        var error: String?

        var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
        var isActive: Bool { state == .queued || state == .running }
    }

    static let backgroundTaskIdentifier = "com.vanities.earmark.transfers"

    /// Persisted to Application Support so a queue survives iOS terminating the suspended app.
    private(set) var jobs: [Job] = [] {
        didSet { persistQueue() }
    }

    @ObservationIgnored private let store = LibraryStore()
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private let cancelled = OSAllocatedUnfairLock(initialState: Set<UUID>())
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var backgroundTask: BGProcessingTask?
    @ObservationIgnored private var queueGeneration = 0
    @ObservationIgnored private let writtenGeneration = OSAllocatedUnfairLock(initialState: 0)

    init(library: LibraryModel) {
        self.library = library
        restoreQueue()
        registerBackgroundTask()
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeInterrupted(reason: "foreground") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleBackgroundProcessingIfNeeded() }
        })
    }

    // MARK: Persistence

    /// `nonisolated`: the save that writes it runs off the main actor.
    private nonisolated static let queueFile = "transfers.json"

    /// Saves run off the main actor and can finish out of order. An older snapshot landing on a
    /// newer one brought a finished download back as pending on the next launch, and it fetched
    /// the book again — even one the user had since removed. Each save carries its generation,
    /// and only a newer one than what's on disk is written.
    private func persistQueue() {
        guard !restoring else { return }
        queueGeneration += 1
        let generation = queueGeneration, snapshot = jobs, store = self.store, written = writtenGeneration
        Task.detached(priority: .utility) {
            written.withLock { newest in
                guard generation > newest else { return }
                newest = generation
                try? store.saveJSON(snapshot, named: DownloadManager.queueFile)
            }
        }
    }

    /// Jobs that were queued or running when the app died come back as queued; finished ones stay listed.
    private func restoreQueue() {
        restoring = true
        defer { restoring = false }
        guard var saved = store.loadJSON([Job].self, named: Self.queueFile), !saved.isEmpty else { return }
        var pending = 0
        for index in saved.indices where saved[index].state == .running || saved[index].state == .queued {
            saved[index].state = .queued
            saved[index].error = nil
            pending += 1
        }
        jobs = saved
        Logger.downloads.info("[downloads] restored \(saved.count) job(s), \(pending) pending")
        if pending > 0 {
            Task { @MainActor [weak self] in self?.runNext() }
        }
    }

    // MARK: Keeping transfers alive

    /// Interrupted jobs (iOS suspended us mid-transfer, network blip) go back in the queue, up to 3 tries.
    private func resumeInterrupted(reason: String) {
        var requeued = 0
        for index in jobs.indices where jobs[index].state == .failed {
            let key = jobs[index].bookID
            guard (attempts[key] ?? 0) < 3 else { continue }
            attempts[key, default: 0] += 1
            jobs[index].state = .queued
            jobs[index].error = nil
            requeued += 1
        }
        if requeued > 0 {
            Logger.downloads.info("[downloads] requeued \(requeued) interrupted job(s) on \(reason, privacy: .public)")
            runNext()
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isSyncing
    }

    private func registerBackgroundTask() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil) { [weak self] task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor [weak self] in self?.runInBackground(task) }
        }
        Logger.downloads.info("[downloads] background task registered=\(registered)")
    }

    /// Ask iOS for processing time later (typically when idle/charging) if work is pending.
    private func scheduleBackgroundProcessingIfNeeded() {
        guard jobs.contains(where: \.isActive) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.downloads.info("[downloads] background processing scheduled")
        } catch {
            Logger.downloads.error("[downloads] background scheduling failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runInBackground(_ task: BGProcessingTask) {
        Logger.downloads.info("[downloads] background processing started")
        backgroundTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Logger.downloads.info("[downloads] background time expiring — pausing")
                // Stop the current job between chunks; it resumes from its partial file later.
                if let running = self.jobs.first(where: { $0.state == .running }) { self.cancel(running.id) }
                self.scheduleBackgroundProcessingIfNeeded()
                task.setTaskCompleted(success: false)
                self.backgroundTask = nil
            }
        }
        resumeInterrupted(reason: "background task")
        for index in jobs.indices where jobs[index].state == .cancelled && (attempts[jobs[index].bookID] ?? 0) < 3 {
            jobs[index].state = .queued
        }
        runNext()
        if !jobs.contains(where: \.isActive) {
            task.setTaskCompleted(success: true)
            backgroundTask = nil
        }
    }

    func job(for bookID: String) -> Job? {
        jobs.last { $0.bookID == bookID }
    }

    func download(_ book: Book) {
        guard library.isRemote(book) else { return }
        if let existing = job(for: book.id), existing.isActive { return }
        jobs.removeAll { $0.bookID == book.id && !$0.isActive }
        jobs.append(Job(id: UUID(), bookID: book.id, title: book.title, totalBytes: max(book.totalBytes, 1)))
        Logger.downloads.info("[downloads] queued \(book.title, privacy: .public) bytes=\(book.totalBytes)")
        runNext()
    }

    /// Remote books in `source` that have no local copy and aren't already queued.
    func pendingSync(for source: LibrarySource) -> [Book] {
        library.books(inSource: source.id).filter { book in
            library.localTwin(of: book) == nil && !(job(for: book.id)?.isActive ?? false)
        }
    }

    /// "Sync from NAS": queue everything that isn't on this phone yet. Files already present
    /// with the right size are skipped, so re-running only fetches what's new.
    func syncAll(from source: LibrarySource) -> Int {
        let books = pendingSync(for: source)
        Logger.downloads.info("[downloads] sync from \(source.displayName, privacy: .public): \(books.count) books")
        for book in library.sorted(books, by: .author) {
            download(book)
        }
        return books.count
    }

    var isSyncing: Bool { jobs.contains(where: \.isActive) }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job.id) }
    }

    // MARK: Moving local books into "On My iPhone › Earmark"

    /// Books in a picked folder (BookPlayer, Downloads…) that can be moved into Earmark's own folder.
    func movable(in source: LibrarySource) -> [Book] {
        guard source.kind == .folder else { return [] }
        return library.books(inSource: source.id).filter { !(job(for: $0.id)?.isActive ?? false) }
    }

    func move(_ book: Book) {
        guard library.source(for: book)?.kind == .folder else { return }
        if let existing = job(for: book.id), existing.isActive { return }
        jobs.removeAll { $0.bookID == book.id && !$0.isActive }
        jobs.append(Job(id: UUID(), bookID: book.id, title: book.title, kind: .move, totalBytes: max(book.totalBytes, 1)))
        Logger.downloads.info("[downloads] queued move \(book.title, privacy: .public) bytes=\(book.totalBytes)")
        runNext()
    }

    /// "Move All into Earmark": every book in the folder, one at a time.
    func moveAll(from source: LibrarySource) -> Int {
        let books = movable(in: source)
        for book in library.sorted(books, by: .author) { move(book) }
        return books.count
    }

    // MARK: Mirroring local books up to the NAS

    /// The NAS this phone mirrors to (its first configured server), if any.
    var mirrorServerID: UUID? { library.nasServers.first?.id }

    /// Local books not already present on the NAS (by relative path) and not already queued.
    func mirrorable(in source: LibrarySource) -> [Book] {
        guard source.kind == .appDocuments || source.kind == .folder, mirrorServerID != nil else { return [] }
        return library.books(inSource: source.id).filter { book in
            library.remoteTwin(of: book) == nil && !(job(for: book.id)?.isActive ?? false)
        }
    }

    func mirror(_ book: Book, to serverID: UUID) {
        if let existing = job(for: book.id), existing.isActive { return }
        jobs.removeAll { $0.bookID == book.id && !$0.isActive }
        var job = Job(id: UUID(), bookID: book.id, title: book.title, kind: .mirror, totalBytes: max(book.totalBytes, 1))
        job.serverID = serverID
        jobs.append(job)
        Logger.downloads.info("[downloads] queued mirror \(book.title, privacy: .public) bytes=\(book.totalBytes)")
        runNext()
    }

    /// "Mirror to NAS": upload every local book that isn't on the NAS yet, one at a time.
    func mirrorAll(from source: LibrarySource) -> Int {
        guard let serverID = mirrorServerID else { return 0 }
        let books = mirrorable(in: source)
        Logger.downloads.info("[downloads] mirror from \(source.displayName, privacy: .public): \(books.count) books")
        for book in library.sorted(books, by: .author) { mirror(book, to: serverID) }
        return books.count
    }

    func cancel(_ jobID: UUID) {
        cancelled.withLock { _ = $0.insert(jobID) }
        if let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .queued {
            jobs[index].state = .cancelled
        }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    /// Tries a failed transfer again, as Mango's Retry does; a download resumes from its partial file.
    func retry(_ jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), !jobs[index].isActive else { return }
        attempts[jobs[index].bookID] = 0
        cancelled.withLock { _ = $0.remove(jobID) }
        jobs[index].state = .queued
        jobs[index].error = nil
        Logger.downloads.info("[downloads] retry \(self.jobs[index].title, privacy: .public)")
        runNext()
    }

    private func runNext() {
        defer { updateIdleTimer() }
        guard runner == nil, let index = jobs.firstIndex(where: { $0.state == .queued }) else {
            if runner == nil, let task = backgroundTask, !jobs.contains(where: \.isActive) {
                task.setTaskCompleted(success: true)
                backgroundTask = nil
                Logger.downloads.info("[downloads] background processing finished")
            }
            return
        }
        jobs[index].state = .running
        let job = jobs[index]
        runner = Task { [weak self] in
            await self?.perform(job)
            self?.runner = nil
            self?.runNext()
        }
    }

    private func update(_ jobID: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        change(&jobs[index])
    }

    /// Copy → check → remove the originals, through ShelfKit's `LocalMove`, off the main actor:
    /// nothing already in Earmark's folder is ever overwritten, and a file already there byte for
    /// byte counts as moved (that's how duplicates collapse). Folders the book leaves empty go,
    /// up to the folder the user picked. Everything done to the book comes along.
    private func performMove(_ job: Job) async {
        guard let book = library.book(id: job.bookID), let root = library.rootURL(for: book.sourceID), let local = library.appDocumentsSource else {
            update(job.id) { $0.state = .failed; $0.error = "This book's folder isn't available." }
            return
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "earmark.move")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let sw = Stopwatch()
        let documents = LibraryModel.documentsURL

        // The audio, plus the images that are the book's (`imagesMoving`) — its own folder's
        // too, where a cover sits above the disc folders.
        var relatives = book.tracks.map(\.relativePath)
        var folders = Set(book.tracks.map { ($0.relativePath as NSString).deletingLastPathComponent })
        if book.kind == .folder { folders.insert(book.relativePath) }
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: folder).path(percentEncoded: false))) ?? []
            relatives += Self.imagesMoving(with: book, from: names).map { folder.isEmpty ? $0 : folder + "/" + $0 }
        }
        let files = relatives.map { rel in
            let source = root.appending(path: rel)
            return LocalMove.File(source: source, destination: documents.appending(path: rel),
                                  size: Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        update(job.id) { $0.totalBytes = max(1, files.reduce(0) { $0 + $1.size }) }

        let jobID = job.id, cancelled = self.cancelled
        let outcome: Result<Void, any Error> = await Task.detached(priority: .userInitiated) {
            Result {
                try LocalMove.run(files, into: "Earmark", pruningUpTo: root, progress: { bytes in
                    Task { @MainActor [weak self] in self?.update(jobID) { $0.doneBytes = bytes } }
                }, isCancelled: { cancelled.withLock { $0.contains(jobID) } })
            }
        }.value
        var originalsNote: String?
        switch outcome {
        case .success:
            break
        case .failure(LocalMove.Failure.originalsLeft(let count, let app)):
            originalsNote = LocalMove.Failure.originalsLeft(count, app: app).errorDescription
        case .failure(LocalMove.Failure.cancelled):
            update(job.id) { $0.state = .cancelled }
            Logger.downloads.info("[downloads] move cancelled \(book.title, privacy: .public)")
            return
        case .failure(let error):
            Logger.downloads.error("[downloads] move failed \(book.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            update(job.id) { $0.state = .failed; $0.error = error.localizedDescription }
            return
        }
        // A new identity in Earmark's folder, and everything done to the book goes with it.
        library.handOverState(from: book.id, to: Book.makeID(sourceID: local.id, relativePath: book.relativePath, groupKey: book.groupKey ?? ""),
                              filesMoved: true)
        update(job.id) {
            $0.state = .done
            $0.doneBytes = $0.totalBytes
            if let originalsNote { $0.error = originalsNote }
        }
        Logger.downloads.info("[downloads] moved \(book.title, privacy: .public) files=\(files.count)\(originalsNote == nil ? "" : " (some originals left)", privacy: .public) in \(sw.seconds, format: .fixed(precision: 1))s")
        library.rescan(local.id)
        library.rescan(book.sourceID)
    }

    /// The pictures that move with a book. A folder that is the book: every image in it (its
    /// cover, whatever it's called). A folder it shares with other books: only an image named
    /// like one of its own files ("Dune.jpg" beside "Dune.m4b") — a neighbour's cover stays.
    nonisolated static func imagesMoving(with book: Book, from names: [String]) -> [String] {
        let images = names.filter { AudioFileTypes.images.contains(($0 as NSString).pathExtension.lowercased()) }
        if book.kind == .folder, (book.groupKey ?? "").isEmpty { return images }
        let stems = Set(book.tracks.map { ($0.fileName as NSString).deletingPathExtension.normalizedForMatching })
        return images.filter { stems.contains(($0 as NSString).deletingPathExtension.normalizedForMatching) }
    }

    /// Uploads a local book's files to the NAS, skipping any already there at the right size, keeping
    /// the same relative layout so the mirrored copy groups exactly like the local one.
    private func performMirror(_ job: Job) async {
        guard let serverID = job.serverID,
              let book = library.book(id: job.bookID),
              let root = library.rootURL(for: book.sourceID),
              let client = library.client(forServer: serverID) else {
            update(job.id) { $0.state = .failed; $0.error = "This book or the NAS isn't available." }
            return
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "earmark.mirror")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let sw = Stopwatch()
        let fileManager = FileManager.default

        var relatives = book.tracks.map(\.relativePath)
        let folders = Set(book.tracks.map { ($0.relativePath as NSString).deletingLastPathComponent })
        for folder in folders {
            let folderURL = root.appending(path: folder)
            if let names = try? fileManager.contentsOfDirectory(atPath: folderURL.path) {
                for name in names where AudioFileTypes.images.contains((name as NSString).pathExtension.lowercased()) {
                    relatives.append(folder.isEmpty ? name : folder + "/" + name)
                }
            }
        }
        let files: [(url: URL, rel: String, size: Int64)] = relatives.map { rel in
            let url = root.appending(path: rel)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return (url, rel, size)
        }
        update(job.id) { $0.totalBytes = max(1, files.reduce(0) { $0 + $1.size }) }

        var done: Int64 = 0
        for file in files {
            if cancelled.withLock({ $0.contains(job.id) }) {
                update(job.id) { $0.state = .cancelled }
                return
            }
            if let remoteSize = await client.remoteSizeIfExists(file.rel), remoteSize == file.size {
                done += file.size
                update(job.id) { $0.doneBytes = done }
                continue
            }
            let base = done
            let jobID = job.id
            let cancelled = self.cancelled
            do {
                try await client.upload(file.url, to: file.rel) { written, _ in
                    Task { @MainActor [weak self] in self?.update(jobID) { $0.doneBytes = base + written } }
                    return !cancelled.withLock { $0.contains(jobID) }
                }
            } catch is CancellationError {
                update(job.id) { $0.state = .cancelled }
                return
            } catch {
                Logger.downloads.error("[downloads] mirror upload failed \(file.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                update(job.id) { $0.state = .failed; $0.error = "Couldn't upload \(file.url.lastPathComponent): \(error.localizedDescription)" }
                return
            }
            done += file.size
            update(job.id) { $0.doneBytes = done }
        }
        update(job.id) { $0.state = .done; $0.doneBytes = $0.totalBytes }
        Logger.downloads.info("[downloads] mirrored \(book.title, privacy: .public) files=\(files.count) in \(sw.seconds, format: .fixed(precision: 1))s")
        // Surface the mirrored book as a remote twin (hidden in the shelf while the local copy exists).
        if let nasSource = library.sources.first(where: { $0.serverID == serverID }) {
            library.rescan(nasSource.id)
        }
    }

    private func perform(_ job: Job) async {
        if job.kind == .move {
            await performMove(job)
            return
        }
        if job.kind == .mirror {
            await performMirror(job)
            return
        }
        guard let book = library.book(id: job.bookID), let client = library.client(for: book) else {
            update(job.id) { $0.state = .failed; $0.error = "This book's NAS isn't available." }
            return
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "earmark.download")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let sw = Stopwatch()

        // Everything the book needs: its audio files plus cover images sitting next to them.
        var files: [(remote: String, size: Int64)] = book.tracks.map { ($0.relativePath, $0.fileSize) }
        let folder = book.kind == .folder ? book.relativePath : (book.relativePath as NSString).deletingLastPathComponent
        if let siblings = try? await client.list(folder) {
            let stem = ((book.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension.normalizedForMatching
            for entry in siblings where !entry.isDirectory {
                let ext = (entry.name as NSString).pathExtension.lowercased()
                guard AudioFileTypes.images.contains(ext) else { continue }
                let imageStem = ((entry.name as NSString).deletingPathExtension).normalizedForMatching
                if book.kind == .folder || imageStem == stem || AudioFileTypes.coverStems.contains(where: { imageStem.hasPrefix($0) }) {
                    files.append((entry.relativePath, entry.size))
                }
            }
        }
        update(job.id) { $0.totalBytes = max(1, files.reduce(0) { $0 + $1.size }) }

        let documents = LibraryModel.documentsURL
        var done: Int64 = 0
        for file in files {
            if cancelled.withLock({ $0.contains(job.id) }) {
                update(job.id) { $0.state = .cancelled }
                Logger.downloads.info("[downloads] cancelled \(book.title, privacy: .public)")
                return
            }
            let destination = documents.appending(path: file.remote)
            if let existing = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(existing) == file.size, file.size > 0 {
                done += file.size
                update(job.id) { $0.doneBytes = done }
                continue
            }
            let partial = destination.appendingPathExtension("part")
            let base = done
            let jobID = job.id
            let cancelled = self.cancelled
            do {
                try await client.download(file.remote, to: partial) { bytes, _ in
                    Task { @MainActor [weak self] in self?.update(jobID) { $0.doneBytes = base + bytes } }
                    return !cancelled.withLock { $0.contains(jobID) }
                }
                if cancelled.withLock({ $0.contains(job.id) }) {
                    update(job.id) { $0.state = .cancelled }
                    return
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                done += file.size
                update(job.id) { $0.doneBytes = done }
            } catch is CancellationError {
                // keep the .part file: the next attempt resumes from it
                update(job.id) { $0.state = .cancelled }
                Logger.downloads.info("[downloads] cancelled \(book.title, privacy: .public)")
                return
            } catch {
                Logger.downloads.error("[downloads] failed \(file.remote, privacy: .public): \(error.localizedDescription, privacy: .public) (partial kept for resume)")
                update(job.id) { $0.state = .failed; $0.error = error.localizedDescription }
                return
            }
        }
        update(job.id) { $0.state = .done; $0.doneBytes = $0.totalBytes }
        Logger.downloads.info("[downloads] done \(book.title, privacy: .public) files=\(files.count) in \(sw.seconds, format: .fixed(precision: 1))s")
        library.noteDownloaded(book.id)
        if let local = library.sources.first(where: { $0.kind == .appDocuments }) {
            library.rescan(local.id)
        }
    }
}
