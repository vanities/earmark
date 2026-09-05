import Foundation
import os

struct ScanProgress: Sendable, Equatable {
    enum Phase: Sendable { case enumerating, metadata, artwork }
    var phase: Phase
    var processed: Int
    var total: Int
}

struct ScanResult: Sendable {
    var books: [Book]
    var unsupportedFiles: [String]
    var fileCount: Int
    var elapsed: TimeInterval
}

enum ScanError: LocalizedError {
    case cannotEnumerate(String)

    var errorDescription: String? {
        switch self {
        case .cannotEnumerate(let path): "Couldn't read the folder at \(path)."
        }
    }
}

/// Walks a source folder, reads tags (with caching), groups files into books, and
/// resolves cover art. Runs entirely off the main actor.
struct LibraryScanner: Sendable {
    let reader = MetadataReader()
    let cache: MetadataCache
    let artwork: ArtworkStore
    var maxConcurrentReads = 4

    private struct Walk: Sendable {
        var audio: [ScannedFile] = []
        var imagesByDirectory: [String: [String]] = [:]
        var unsupported: [String] = []
        var imageCount = 0
    }

    func scan(source: LibrarySource, root: URL, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        let sw = Stopwatch()
        Logger.scan.info("[scan] start source=\(source.displayName, privacy: .public) kind=\(source.kind.rawValue, privacy: .public)")
        progress(ScanProgress(phase: .enumerating, processed: 0, total: 0))

        let walk = try walkTree(root: root, isSingleFile: source.kind == .file)
        try Task.checkCancellation()
        Logger.scan.info("[scan] enumerated audio=\(walk.audio.count) images=\(walk.imageCount) unsupported=\(walk.unsupported.count) in \(sw.ms, format: .fixed(precision: 0))ms")

        var files = walk.audio
        let total = files.count
        var processed = 0
        var lastReport = Date.distantPast
        var cacheHits = 0
        progress(ScanProgress(phase: .metadata, processed: 0, total: total))

        try await withThrowingTaskGroup(of: (Int, AudioMetadata?, Bool).self) { group in
            var next = 0
            for _ in 0..<min(maxConcurrentReads, files.count) {
                enqueue(files[next], index: next, sourceID: source.id, root: root, into: &group)
                next += 1
            }
            while let (index, metadata, fromCache) = try await group.next() {
                files[index].metadata = metadata
                processed += 1
                if fromCache { cacheHits += 1 }
                if Date().timeIntervalSince(lastReport) > 0.2 || processed == total {
                    lastReport = Date()
                    progress(ScanProgress(phase: .metadata, processed: processed, total: total))
                }
                if processed % 25 == 0 { await cache.flush() } // resumable: a crash mid-scan keeps what was read
                if next < files.count {
                    enqueue(files[next], index: next, sourceID: source.id, root: root, into: &group)
                    next += 1
                }
            }
        }
        await cache.flush()
        try Task.checkCancellation()
        Logger.scan.info("[scan] metadata done files=\(total) cacheHits=\(cacheHits) at \(sw.ms, format: .fixed(precision: 0))ms")

        let drafts = BookGrouper.group(BookGrouper.Input(
            sourceID: source.id,
            sourceName: source.displayName,
            files: files,
            imagesByDirectory: walk.imagesByDirectory
        ))

        progress(ScanProgress(phase: .artwork, processed: 0, total: drafts.count))
        var books: [Book] = []
        for (index, draft) in drafts.enumerated() {
            try Task.checkCancellation()
            var book = draft.book
            book.artworkID = await resolveArtwork(for: draft, root: root)
            books.append(book)
            progress(ScanProgress(phase: .artwork, processed: index + 1, total: drafts.count))
        }

        Logger.scan.info("[scan] done source=\(source.displayName, privacy: .public) books=\(books.count) files=\(total) in \(sw.ms, format: .fixed(precision: 0))ms")
        return ScanResult(books: books, unsupportedFiles: walk.unsupported, fileCount: total, elapsed: sw.seconds)
    }

    // MARK: - Remote (SMB)

    /// Same pipeline as `scan`, but the directory walk, tag reads, and cover fetches go over SMB.
    func scanRemote(source: LibrarySource, client: NASClient, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        let sw = Stopwatch()
        Logger.scan.info("[scan] remote start source=\(source.displayName, privacy: .public) root=\(client.server.displayLocation, privacy: .public)")
        progress(ScanProgress(phase: .enumerating, processed: 0, total: 0))

        var walk = Walk()
        var pending = [""]
        var visited = 0
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            let entries = try await client.list(directory)
            visited += 1
            for entry in entries where !entry.name.hasPrefix(".") {
                if entry.isDirectory {
                    pending.append(entry.relativePath)
                    continue
                }
                let ext = (entry.name as NSString).pathExtension.lowercased()
                if AudioFileTypes.playable.contains(ext) {
                    walk.audio.append(ScannedFile(relativePath: entry.relativePath, fileSize: entry.size, modifiedAt: entry.modifiedAt, metadata: nil))
                } else if AudioFileTypes.images.contains(ext) {
                    walk.imagesByDirectory[(entry.relativePath as NSString).deletingLastPathComponent, default: []].append(entry.relativePath)
                    walk.imageCount += 1
                } else if AudioFileTypes.unsupported.contains(ext) {
                    walk.unsupported.append(entry.relativePath)
                }
            }
            if visited % 5 == 0 { progress(ScanProgress(phase: .enumerating, processed: walk.audio.count, total: 0)) }
        }
        Logger.scan.info("[scan] remote enumerated dirs=\(visited) audio=\(walk.audio.count) images=\(walk.imageCount) in \(sw.ms, format: .fixed(precision: 0))ms")

        var files = walk.audio
        let total = files.count
        var processed = 0
        var cacheHits = 0
        progress(ScanProgress(phase: .metadata, processed: 0, total: total))
        try await withThrowingTaskGroup(of: (Int, AudioMetadata?, Bool).self) { group in
            var next = 0
            let concurrency = 2
            for _ in 0..<min(concurrency, files.count) {
                enqueueRemote(files[next], index: next, sourceID: source.id, client: client, into: &group)
                next += 1
            }
            while let (index, metadata, fromCache) = try await group.next() {
                files[index].metadata = metadata
                processed += 1
                if fromCache { cacheHits += 1 }
                progress(ScanProgress(phase: .metadata, processed: processed, total: total))
                if processed % 10 == 0 { await cache.flush() } // remote reads are slow; keep progress often
                if next < files.count {
                    enqueueRemote(files[next], index: next, sourceID: source.id, client: client, into: &group)
                    next += 1
                }
            }
        }
        await cache.flush()
        try Task.checkCancellation()
        Logger.scan.info("[scan] remote metadata done files=\(total) cacheHits=\(cacheHits) at \(sw.ms, format: .fixed(precision: 0))ms")

        let drafts = BookGrouper.group(BookGrouper.Input(sourceID: source.id, sourceName: source.displayName, files: files, imagesByDirectory: walk.imagesByDirectory))
        progress(ScanProgress(phase: .artwork, processed: 0, total: drafts.count))
        var books: [Book] = []
        for (index, draft) in drafts.enumerated() {
            try Task.checkCancellation()
            var book = draft.book
            book.artworkID = await resolveRemoteArtwork(for: draft, client: client)
            books.append(book)
            progress(ScanProgress(phase: .artwork, processed: index + 1, total: drafts.count))
        }
        Logger.scan.info("[scan] remote done source=\(source.displayName, privacy: .public) books=\(books.count) files=\(total) in \(sw.ms, format: .fixed(precision: 0))ms")
        return ScanResult(books: books, unsupportedFiles: walk.unsupported, fileCount: total, elapsed: sw.seconds)
    }

    private func enqueueRemote(_ file: ScannedFile, index: Int, sourceID: UUID, client: NASClient, into group: inout ThrowingTaskGroup<(Int, AudioMetadata?, Bool), any Error>) {
        let key = "\(sourceID.uuidString)|\(file.relativePath)"
        let cache = cache
        let reader = reader
        group.addTask {
            try Task.checkCancellation()
            if let cached = await cache.metadata(forKey: key, fileSize: file.fileSize, modifiedAt: file.modifiedAt) {
                return (index, cached, true)
            }
            if file.ext == "mp3", let quick = await Self.quickRemoteMP3(file, client: client) {
                await cache.store(quick, forKey: key, fileSize: file.fileSize, modifiedAt: file.modifiedAt)
                return (index, quick, false)
            }
            let (asset, loader) = client.makeAsset(relativePath: file.relativePath, size: file.fileSize)
            defer { _ = loader }
            do {
                let metadata = try await reader.read(asset: asset, name: file.fileName)
                await cache.store(metadata, forKey: key, fileSize: file.fileSize, modifiedAt: file.modifiedAt)
                return (index, metadata, false)
            } catch {
                Logger.scan.error("[scan] remote tags failed for \(file.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return (index, nil, false)
            }
        }
    }

    /// Tags + duration from the head of a remote MP3 (a few hundred KB) instead of the whole file.
    private static func quickRemoteMP3(_ file: ScannedFile, client: NASClient) async -> AudioMetadata? {
        let sw = Stopwatch()
        do {
            var head = try await client.readAll(file.relativePath, maxBytes: Int64(QuickTagReader.initialWindow))
            let needed = QuickTagReader.requiredLength(head)
            if needed > head.count, Int64(head.count) < file.fileSize {
                let more = OSAllocatedUnfairLock(initialState: Data())
                try await client.read(file.relativePath, offset: Int64(head.count), length: Int64(needed - head.count)) { chunk in
                    more.withLock { $0.append(chunk) }
                    return true
                }
                head.append(more.withLock { $0 })
            }
            guard let metadata = QuickTagReader.parseMP3(head: head, fileSize: file.fileSize) else {
                Logger.metadata.notice("[metadata] quick parse failed for \(file.fileName, privacy: .public) — falling back to AVFoundation")
                return nil
            }
            Logger.metadata.debug("[metadata] quick \(file.fileName, privacy: .public) dur=\(metadata.duration, format: .fixed(precision: 1))s bytes=\(head.count) in \(sw.ms, format: .fixed(precision: 0))ms")
            return metadata
        } catch {
            Logger.metadata.error("[metadata] quick read failed for \(file.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func resolveRemoteArtwork(for draft: BookDraft, client: NASClient) async -> String? {
        let id = artwork.id(for: draft.book.id)
        if artwork.hasImage(id: id) { return id }
        for candidate in draft.artworkCandidates {
            let data: Data?
            switch candidate.kind {
            case .embedded:
                guard let track = draft.book.tracks.first(where: { $0.relativePath == candidate.relativePath }) else { continue }
                let (asset, loader) = client.makeAsset(relativePath: candidate.relativePath, size: track.fileSize)
                data = await reader.artworkData(asset: asset)
                _ = loader
            case .imageFile:
                data = try? await client.readAll(candidate.relativePath)
            }
            if let data, artwork.store(imageData: data, id: id) {
                return id
            }
        }
        return nil
    }

    // MARK: - Metadata

    private func enqueue(_ file: ScannedFile, index: Int, sourceID: UUID, root: URL, into group: inout ThrowingTaskGroup<(Int, AudioMetadata?, Bool), any Error>) {
        let url = root.appending(path: file.relativePath)
        let key = "\(sourceID.uuidString)|\(file.relativePath)"
        let cache = cache
        let reader = reader
        group.addTask {
            try Task.checkCancellation()
            if let cached = await cache.metadata(forKey: key, fileSize: file.fileSize, modifiedAt: file.modifiedAt) {
                return (index, cached, true)
            }
            if file.needsDownload {
                Logger.scan.notice("[scan] skipping tags for not-downloaded file \(file.fileName, privacy: .public)")
                return (index, nil, false)
            }
            do {
                let metadata = try await reader.read(url: url)
                await cache.store(metadata, forKey: key, fileSize: file.fileSize, modifiedAt: file.modifiedAt)
                return (index, metadata, false)
            } catch {
                Logger.scan.error("[scan] tags failed for \(file.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return (index, nil, false)
            }
        }
    }

    // MARK: - Walking

    private func walkTree(root: URL, isSingleFile: Bool) throws -> Walk {
        var walk = Walk()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]

        if isSingleFile {
            let values = try? root.resourceValues(forKeys: keys)
            walk.audio.append(scannedFile(url: root, relativePath: root.lastPathComponent, values: values))
            return walk
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                Logger.scan.error("[scan] enumerate error at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return true
            }
        ) else {
            throw ScanError.cannotEnumerate(root.lastPathComponent)
        }

        var rootPath = root.standardizedFileURL.path(percentEncoded: false)
        while rootPath.hasSuffix("/") { rootPath.removeLast() }

        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited % 500 == 0 { try Task.checkCancellation() }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            let relative = relativePath(of: url, rootPath: rootPath)
            let ext = url.pathExtension.lowercased()
            if AudioFileTypes.playable.contains(ext) {
                walk.audio.append(scannedFile(url: url, relativePath: relative, values: values))
            } else if AudioFileTypes.images.contains(ext) {
                walk.imagesByDirectory[(relative as NSString).deletingLastPathComponent, default: []].append(relative)
                walk.imageCount += 1
            } else if AudioFileTypes.unsupported.contains(ext) {
                walk.unsupported.append(relative)
            }
        }
        return walk
    }

    private func scannedFile(url: URL, relativePath: String, values: URLResourceValues?) -> ScannedFile {
        let isCloud = values?.isUbiquitousItem == true
        let status = values?.ubiquitousItemDownloadingStatus
        let needsDownload = isCloud && status != nil && status != .current && status != .downloaded
        return ScannedFile(
            relativePath: relativePath,
            fileSize: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate,
            metadata: nil,
            needsDownload: needsDownload
        )
    }

    private func relativePath(of url: URL, rootPath: String) -> String {
        let full = url.standardizedFileURL.path(percentEncoded: false)
        guard full.hasPrefix(rootPath) else { return url.lastPathComponent }
        var relative = String(full.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    // MARK: - Artwork

    private func resolveArtwork(for draft: BookDraft, root: URL) async -> String? {
        let id = artwork.id(for: draft.book.id)
        if artwork.hasImage(id: id) { return id }
        for candidate in draft.artworkCandidates {
            let url = root.appending(path: candidate.relativePath)
            let data: Data?
            switch candidate.kind {
            case .embedded: data = await reader.artworkData(url: url)
            case .imageFile: data = try? Data(contentsOf: url)
            }
            if let data, artwork.store(imageData: data, id: id) {
                Logger.scan.debug("[scan] artwork for \(draft.book.title, privacy: .public) from \(candidate.relativePath, privacy: .public)")
                return id
            }
        }
        return nil
    }
}
