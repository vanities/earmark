import Foundation
import Observation
import UIKit
import os

/// Copies remote books into "On My iPhone › Earmark", one at a time, keeping the same
/// relative folder layout so the local copy groups exactly like the remote one did.
@MainActor @Observable
final class DownloadManager {
    struct Job: Identifiable, Equatable {
        enum State: Equatable { case queued, running, done, failed, cancelled }
        let id: UUID
        let bookID: String
        let title: String
        var totalBytes: Int64
        var doneBytes: Int64 = 0
        var state: State = .queued
        var error: String?

        var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
        var isActive: Bool { state == .queued || state == .running }
    }

    private(set) var jobs: [Job] = []

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private let cancelled = OSAllocatedUnfairLock(initialState: Set<UUID>())

    init(library: LibraryModel) {
        self.library = library
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

    func cancel(_ jobID: UUID) {
        cancelled.withLock { _ = $0.insert(jobID) }
        if let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .queued {
            jobs[index].state = .cancelled
        }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    private func runNext() {
        guard runner == nil, let index = jobs.firstIndex(where: { $0.state == .queued }) else { return }
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

    private func perform(_ job: Job) async {
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
                    try? FileManager.default.removeItem(at: partial)
                    update(job.id) { $0.state = .cancelled }
                    return
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                done += file.size
                update(job.id) { $0.doneBytes = done }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: partial)
                update(job.id) { $0.state = .cancelled }
                Logger.downloads.info("[downloads] cancelled \(book.title, privacy: .public)")
                return
            } catch {
                try? FileManager.default.removeItem(at: partial)
                Logger.downloads.error("[downloads] failed \(file.remote, privacy: .public): \(error.localizedDescription, privacy: .public)")
                update(job.id) { $0.state = .failed; $0.error = error.localizedDescription }
                return
            }
        }
        update(job.id) { $0.state = .done; $0.doneBytes = $0.totalBytes }
        Logger.downloads.info("[downloads] done \(book.title, privacy: .public) files=\(files.count) in \(sw.seconds, format: .fixed(precision: 1))s")
        if let local = library.sources.first(where: { $0.kind == .appDocuments }) {
            library.rescan(local.id)
        }
    }
}
