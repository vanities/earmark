import Foundation
import UIKit
import os

// MARK: - Cover art
//
// User-picked covers: applying and syncing them (`CoverChoice`, newest wins across devices via
// `CoverSync`), going back to the original, and the one image Earmark may write beside a book's audio.

extension LibraryModel {
    /// Where a cover the user picked came from.
    enum CoverOrigin: Sendable {
        /// A Find Cover result. Synced by URL, so every device shows it.
        case online(URL)
        /// Photos or Files. Nothing to download elsewhere, so it stays on this device.
        case device
    }

    /// Whether the user picked a cover for this book (so there's an original to go back to).
    func hasCustomCover(_ book: Book) -> Bool { customArtwork[book.id] != nil }

    /// Applies a cover the user picked to a book and its downloaded twin, remembers the choice so it
    /// syncs, and — for books on this phone — saves it next to the audio so other apps see it too.
    func setCustomArtwork(_ data: Data, origin: CoverOrigin, for book: Book) -> Bool {
        let sw = Stopwatch()
        let artwork = ArtworkStore.shared
        let group = books.filter { $0.syncKey == book.syncKey }
        var applied = 0
        for member in group.isEmpty ? [book] : group {
            let id = switch origin {
            case .online(let url): ArtworkStore.customID(for: member.id, sourceURL: url)
            case .device: ArtworkStore.customID(for: member.id, imageData: data)
            }
            guard artwork.store(imageData: data, id: id) else { continue }
            installCustomCover(id, for: member)
            writeCoverFile(data, for: member)
            applied += 1
        }
        guard applied > 0 else {
            Logger.artwork.error("[covers] picked image unusable for \(book.title, privacy: .public) bytes=\(data.count)")
            return false
        }
        coverChoices[book.syncKey] = switch origin {
        case .online(let url): CoverChoice(kind: .online, url: url.absoluteString)
        case .device: CoverChoice(kind: .deviceOnly)
        }
        Logger.artwork.info("[covers] picked cover for \(book.title, privacy: .public) books=\(applied) origin=\(String(describing: origin), privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
        save()
        onBooksChanged?()
        return true
    }

    /// Drops the user's cover for a book — on every device — and goes back to the art its files provide.
    func useOriginalCover(for book: Book) {
        let previous = coverChoices[book.syncKey]
        let group = books.filter { $0.syncKey == book.syncKey }
        let untracked = group.filter { writtenCovers[$0.id] == nil }
        var rescans: Set<UUID> = []
        for member in group {
            let needsRescan = restoreOriginalCover(member)
            if needsRescan { rescans.insert(member.sourceID) }
        }
        coverChoices[book.syncKey] = CoverChoice(kind: .original)
        Logger.artwork.info("[covers] back to the original cover for \(book.title, privacy: .public) rescans=\(rescans.count)")
        save()
        onBooksChanged?()
        for id in rescans { rescan(id) }
        // Builds before cover tracking wrote cover.jpg without recording it, so the original would keep
        // showing the old pick. Such a file is removed only if it's byte-for-byte that pick.
        if let previous, previous.chosenAt == .distantPast, let pickURL = previous.url.flatMap(URL.init(string:)) {
            for member in untracked {
                Task { [weak self] in await self?.removeLegacyCoverFile(for: member, pickedFrom: pickURL) }
            }
        }
    }

    /// Removes a cover.jpg an older build wrote beside a book's audio without tracking it — only when
    /// it's identical to the image at the URL the user had picked, so a cover.jpg they made is never touched.
    private func removeLegacyCoverFile(for book: Book, pickedFrom pickURL: URL) async {
        guard let bookURL = url(forBook: book), source(for: book)?.kind != .file else { return }
        let target = (book.kind == .folder ? bookURL : bookURL.deletingLastPathComponent()).appending(path: "cover.jpg")
        guard let existing = try? Data(contentsOf: target) else { return }
        guard let picked = try? await CoverSearch.download(pickURL), picked == existing else {
            Logger.artwork.info("[covers] keeping \(target.path(percentEncoded: false), privacy: .public) — not the image Earmark wrote")
            return
        }
        do {
            try FileManager.default.removeItem(at: target)
            Logger.artwork.info("[covers] removed legacy cover.jpg for \(book.title, privacy: .public)")
        } catch {
            Logger.artwork.notice("[covers] couldn't remove legacy cover.jpg for \(book.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        // Its scan thumbnail was made from that file; rebuild the book's art from what's left.
        ArtworkStore.shared.remove(id: ArtworkStore.shared.id(for: book.id))
        if customArtwork[book.id] == nil { setArtworkID(nil, forBook: book.id) }
        rescan(book.sourceID)
    }

    /// Points a book at a custom cover already in the art cache, deleting the one it replaces.
    private func installCustomCover(_ id: String, for book: Book) {
        let previous = customArtwork[book.id]
        customArtwork[book.id] = id
        if let previous, previous != id { ArtworkStore.shared.remove(id: previous) }
        setArtworkID(id, forBook: book.id)
        Logger.artwork.debug("[covers] \(book.title, privacy: .public) → id=\(id, privacy: .public) previous=\(previous ?? "-", privacy: .public)")
    }

    /// Drops a book's custom cover on this device. Returns true when its source needs a rescan to
    /// rebuild the book's own art, because the image Earmark had written next to the audio is gone.
    private func restoreOriginalCover(_ book: Book) -> Bool {
        let artwork = ArtworkStore.shared
        if let id = customArtwork.removeValue(forKey: book.id) { artwork.remove(id: id) }
        let scanID = artwork.id(for: book.id)
        let removedFile = removeCoverFile(for: book)
        // The scan's thumbnail may have been made from the image just removed; the rescan rebuilds it.
        if removedFile { artwork.remove(id: scanID) }
        setArtworkID(artwork.hasImage(id: scanID) ? scanID : nil, forBook: book.id)
        return removedFile
    }

    /// Brings every cover on this device in line with the synced choices: fetches covers picked on
    /// another device (or lost with the art cache) and drops ones the user went back from.
    func reconcileCovers() {
        let artwork = ArtworkStore.shared
        let actions = CoverSync.plan(books: books, choices: coverChoices, customArtwork: customArtwork, hasImage: artwork.hasImage(id:))
        guard !actions.isEmpty else { return }
        Logger.artwork.info("[covers] reconcile actions=\(actions.count)")
        var changed = false
        var rescans: Set<UUID> = []
        for (bookID, action) in actions {
            guard let book = book(id: bookID) else { continue }
            switch action {
            case .adopt(let old, let new):
                if artwork.move(from: old, to: new) {
                    installCustomCover(new, for: book)
                    changed = true
                }
            case .removeCustom:
                if restoreOriginalCover(book) { rescans.insert(book.sourceID) }
                changed = true
            case .download(let url, let id):
                let attempt = "\(bookID)|\(id)"
                guard coverDownloadsAttempted.insert(attempt).inserted else { continue }
                Task { [weak self] in await self?.fetchChosenCover(url, id: id, bookID: bookID) }
            }
        }
        if changed {
            save()
            onBooksChanged?()
        }
        for id in rescans { rescan(id) }
    }

    /// Downloads a cover chosen on another device (or lost from the art cache) and installs it,
    /// unless the choice changed while it was downloading.
    private func fetchChosenCover(_ url: URL, id: String, bookID: String) async {
        let sw = Stopwatch()
        let data: Data
        do {
            data = try await CoverSearch.download(url)
        } catch {
            Logger.artwork.notice("[covers] fetch failed for \(bookID, privacy: .public) url=\(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        func stillWanted() -> Book? {
            guard let book = book(id: bookID), coverChoices[book.syncKey]?.url == url.absoluteString else { return nil }
            return book
        }
        guard stillWanted() != nil else { return }
        let artwork = ArtworkStore.shared
        let stored = await Task.detached(priority: .utility) { artwork.store(imageData: data, id: id) }.value
        guard stored, let book = stillWanted() else { return }
        installCustomCover(id, for: book)
        writeCoverFile(data, for: book)
        Logger.artwork.info("[covers] fetched chosen cover for \(book.title, privacy: .public) bytes=\(data.count) in \(sw.ms, format: .fixed(precision: 0))ms")
        save()
        onBooksChanged?()
    }

    /// Where Earmark keeps a chosen cover next to a book's audio: cover.jpg in a book folder, or
    /// "<file name>.jpg" beside a single file (the name the scanner pairs with that file). Nil for books
    /// that aren't on this device, and for a file added on its own, whose folder Earmark can't write.
    private func coverFileURL(for book: Book) -> URL? {
        guard let bookURL = url(forBook: book), source(for: book)?.kind != .file else { return nil }
        switch book.kind {
        case .folder: return bookURL.appending(path: "cover.jpg")
        case .singleFile: return bookURL.deletingPathExtension().appendingPathExtension("jpg")
        }
    }

    /// Saves a chosen cover next to the book's audio. Only ever replaces an image Earmark wrote itself
    /// (checked against the hash in `writtenCovers`), never the user's own.
    private func writeCoverFile(_ data: Data, for book: Book) {
        guard let target = coverFileURL(for: book) else { return }
        if FileManager.default.fileExists(atPath: target.path) {
            guard let written = writtenCovers[book.id], let existing = try? Data(contentsOf: target),
                  ArtworkStore.fingerprint(of: existing) == written else {
                Logger.artwork.info("[covers] leaving existing \(target.lastPathComponent, privacy: .public) for \(book.title, privacy: .public) — not Earmark's")
                return
            }
        }
        guard let jpeg = ArtworkStore.coverJPEG(from: data) else { return }
        do {
            try jpeg.write(to: target, options: .atomic)
            writtenCovers[book.id] = ArtworkStore.fingerprint(of: jpeg)
            Logger.artwork.info("[covers] wrote \(target.lastPathComponent, privacy: .public) for \(book.title, privacy: .public) bytes=\(jpeg.count)")
        } catch {
            Logger.artwork.notice("[covers] couldn't write \(target.lastPathComponent, privacy: .public) for \(book.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes the cover image Earmark wrote next to a book's audio, if it's still the one it wrote.
    /// Returns true when a file was removed.
    private func removeCoverFile(for book: Book) -> Bool {
        guard let written = writtenCovers.removeValue(forKey: book.id), let target = coverFileURL(for: book),
              let existing = try? Data(contentsOf: target), ArtworkStore.fingerprint(of: existing) == written else { return false }
        do {
            try FileManager.default.removeItem(at: target)
            Logger.artwork.info("[covers] removed \(target.lastPathComponent, privacy: .public) for \(book.title, privacy: .public)")
            return true
        } catch {
            Logger.artwork.notice("[covers] couldn't remove \(target.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
