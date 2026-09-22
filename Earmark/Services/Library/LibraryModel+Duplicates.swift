import Foundation
import os

// MARK: - Duplicates

/// Finding the same audio in more than one place, and deleting the copies the user picks.
extension LibraryModel {
    enum DuplicateScanState: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(Date)
    }

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
            guard let root = rootURL(for: file.sourceID) else {
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
}
