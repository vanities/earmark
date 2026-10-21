import AVFoundation
import os
import ShelfKit
import XCTest
@testable import Earmark

@MainActor
final class EarmarkNASAuditTests: XCTestCase {
    @MainActor private final class BackgroundTask {
        var expiration: (@Sendable () -> Void)?
        var completions: [Bool] = []
        lazy var execution = TransferBackgroundExecution(
            setExpirationHandler: { [weak self] in self?.expiration = $0 },
            complete: { [weak self] in self?.completions.append($0) })
        func expire() { expiration?() }
    }

    private func client() throws -> NASClient {
        try NASClient(server: NASServer(id: UUID(), name: "Local fixtures", host: "127.0.0.1", port: 1445,
                                       share: "AUDIT", path: "", username: "audit", addedAt: .now), password: "local-fixture-only")
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for player or transfer state")
    }

    private func withLibrary(_ body: (LibraryModel, AppSettings, NASClient, Book, URL) async throws -> Void) async throws {
        let client = try client()
        try await client.connect()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep temporary state until the test host exits: cover backfills can finish later.
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.smartRewind = false
        let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Local fixture SMB", addedAt: .now, serverID: client.server.id)
        let local = LibrarySource(id: UUID(), kind: .appDocuments, displayName: "On My iPhone", addedAt: .now)
        let file = ScannedFile(relativePath: "Audit Audio.wav", fileSize: try await client.fileSize("Audit Audio.wav"), modifiedAt: nil,
                               metadata: AudioMetadata(duration: 180))
        let book = try XCTUnwrap(BookGrouper.group(.init(sourceID: source.id, sourceName: "Local fixtures", files: [file], imagesByDirectory: [:])).first?.book)
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")), settings: settings)
        library.sources = [source, local]
        library.books = [book]
        library.nasServers = [client.server]
        library.nasClients[client.server.id] = client
        library.resolvedRoots[local.id] = LibraryModel.documentsURL
        try await body(library, settings, client, book, root)
        await client.disconnect()
    }

    func testActualSMBPlaybackSeekingPauseAndReconnect() async throws {
        try await withLibrary { library, settings, client, book, _ in
            let player = PlayerEngine(library: library, settings: settings)
            defer { player.unload() }
            player.load(book, autoplay: true)
            try await self.eventually { player.isPlaying && player.currentTime > 0.5 || player.errorMessage != nil }
            XCTAssertNil(player.errorMessage)
            XCTAssertTrue(player.isPlaying)
            player.skip(by: 50)
            try await self.eventually { !player.isLoading && player.currentTime > 40 }
            player.pause()
            let paused = player.currentTime
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(player.currentTime, paused, accuracy: 0.2)
            await client.disconnect()
            player.seek(toBookOffset: 140)
            player.play()
            try await self.eventually { player.isPlaying && player.currentTime > 140 || player.errorMessage != nil }
            XCTAssertNil(player.errorMessage)
            XCTAssertTrue(player.isPlaying)
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                                            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
            XCTAssertFalse(player.isPlaying)
        }
    }

    func testActualSMBDownloadCancelRetryOfflinePlaybackAndRemoval() async throws {
        try await withLibrary { library, settings, client, book, root in
            let manager = DownloadManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
            let destination = LibraryModel.documentsURL.appending(path: "Audit Audio.wav")
            let partial = destination.appendingPathExtension("part")
            guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: partial.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: partial) }
            manager.download(book)
            try await self.eventually { manager.jobs.first?.doneBytes ?? 0 > 0 }
            let id = try XCTUnwrap(manager.jobs.first?.id)
            manager.cancel(id)
            try await self.eventually { manager.jobs.first?.isActive == false }
            XCTAssertEqual(manager.jobs.first?.state, .cancelled)
            let partialBytes = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            XCTAssertGreaterThan(partialBytes, 0)
            XCTAssertLessThan(Int64(partialBytes), book.totalBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            manager.retry(id)
            try await self.eventually { manager.jobs.first?.isActive == false }
            XCTAssertEqual(manager.jobs.first?.state, .done, manager.jobs.first?.error ?? "")
            XCTAssertEqual(Int64(try Data(contentsOf: destination).count), book.totalBytes)
            try await self.eventually { library.localTwin(of: book) != nil }
            let local = try XCTUnwrap(library.localTwin(of: book))
            await client.disconnect()
            let player = PlayerEngine(library: library, settings: settings)
            defer { player.unload() }
            player.load(local, autoplay: true, startAt: BookPosition(trackIndex: 0, time: 90))
            try await self.eventually { player.isPlaying || player.errorMessage != nil }
            XCTAssertNil(player.errorMessage)
            XCTAssertGreaterThan(player.currentTime, 89)
            player.unload()
            library.removeDownload(of: local)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testServiceLossKeepsDownloadPartialAndExplicitRetryReconnects() async throws {
        let service = try FixtureServiceControl()
        try await service.setRunning(true)
        do {
            try await withLibrary { library, _, _, book, root in
                let destination = LibraryModel.documentsURL.appending(path: book.relativePath)
                let partial = destination.appendingPathExtension("part")
                guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: partial.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: partial) }
                let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures")
                let fixture = fixtures.appending(path: book.relativePath)
                let originalBytes = try Data(contentsOf: fixture)
                let originalModification = try FileManager.default.attributesOfItem(atPath: fixture.path)[.modificationDate] as? Date
                let manager = DownloadManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
                manager.download(book)
                try await self.eventually { manager.jobs.first?.doneBytes ?? 0 > 0 }
                let stopped = try await service.setRunning(false)
                try await self.eventually { manager.jobs.first?.isActive == false }
                XCTAssertEqual(manager.jobs.first?.state, .failed)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                let bytes = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
                XCTAssertGreaterThan(bytes?.int64Value ?? 0, 0)
                XCTAssertLessThan(bytes?.int64Value ?? book.totalBytes, book.totalBytes)
                let restarted = try await service.setRunning(true)
                XCTAssertGreaterThan(restarted.generation, stopped.generation, "Retry must face a fresh SMB service, not a manual client disconnect")
                XCTAssertEqual(try Data(contentsOf: fixture), originalBytes)
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.path)[.modificationDate] as? Date, originalModification)
                manager.retry(try XCTUnwrap(manager.jobs.first?.id))
                try await self.eventually { manager.jobs.first?.isActive == false }
                XCTAssertEqual(manager.jobs.first?.state, .done, manager.jobs.first?.error ?? "")
                XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
            }
        } catch {
            _ = try? await service.setRunning(true)
            throw error
        }
    }

    func testReplacingSameSizeRemoteAudioDoesNotMixVersionsOnRetry() async throws {
        try await exerciseReplacement(growing: false, preserveTimestamp: false)
    }

    func testReplacingLargerRemoteAudioRefreshesCachedSizeOnRetry() async throws {
        try await exerciseReplacement(growing: true, preserveTimestamp: false)
    }

    func testReplacingRemoteAudioWithPreservedTimestampRestartsPartial() async throws {
        try await exerciseReplacement(growing: false, preserveTimestamp: true)
    }

    func testRemoteAudioChangingDuringDownloadIsNotPublished() async throws {
        try await exerciseReplacement(growing: false, preserveTimestamp: false, whileDownloading: true)
    }

    func testRemoteAudioMiddleChangeWithUnchangedMetadataRestartsPartial() async throws {
        try await exerciseReplacement(growing: false, preserveTimestamp: true, middleOnly: true)
    }

    private func exerciseReplacement(growing: Bool, preserveTimestamp: Bool, whileDownloading: Bool = false, middleOnly: Bool = false) async throws {
        try await withLibrary { library, _, client, original, root in
            let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures")
            let old = fixtures.appending(path: ".versions/Audio-old.wav")
            let new = fixtures.appending(path: growing ? ".versions/Audio-grown.wav" : ".versions/Audio-new.wav")
            let oldBytes = try Data(contentsOf: old)
            let changedBytes = try Data(contentsOf: new)
            var newBytes = changedBytes
            let changedRange = 1_048_576..<1_114_112
            if middleOnly {
                newBytes = oldBytes
                newBytes.replaceSubrange(changedRange, with: changedBytes[changedRange])
            }
            if growing { XCTAssertGreaterThan(newBytes.count, oldBytes.count) } else { XCTAssertEqual(oldBytes.count, newBytes.count) }
            XCTAssertNotEqual(oldBytes, newBytes)
            let path = "Replacement Audio.wav"
            let remote = fixtures.appending(path: path)
            guard !FileManager.default.fileExists(atPath: remote.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.copyItem(at: old, to: remote)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: remote.path)
            defer { try? FileManager.default.removeItem(at: remote) }
            let file = ScannedFile(relativePath: path, fileSize: Int64(oldBytes.count), modifiedAt: nil, metadata: AudioMetadata(duration: 180))
            let book = try XCTUnwrap(BookGrouper.group(.init(sourceID: original.sourceID, sourceName: "Generated replacement", files: [file], imagesByDirectory: [:])).first?.book)
            library.books.append(book)
            let destination = LibraryModel.documentsURL.appending(path: path)
            let partial = destination.appendingPathExtension("part")
            guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: partial.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: partial) }
            let manager = DownloadManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
            manager.download(book)
            try await self.eventually { manager.jobs.first?.doneBytes ?? 0 > 0 }
            let id = try XCTUnwrap(manager.jobs.first?.id)
            if !whileDownloading {
                manager.cancel(id)
                try await self.eventually { manager.jobs.first?.isActive == false }
                XCTAssertEqual(manager.jobs.first?.state, .cancelled)
            }
            let partialSize = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
            XCTAssertGreaterThan(partialSize?.intValue ?? 0, 0)
            XCTAssertLessThan(partialSize?.intValue ?? oldBytes.count, oldBytes.count)
            try FileManager.default.removeItem(at: remote)
            if middleOnly { try newBytes.write(to: remote) } else { try FileManager.default.copyItem(at: new, to: remote) }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: preserveTimestamp ? 1_000_000_000 : 1_000_000_100)], ofItemAtPath: remote.path)
            let freshPrefix = try await client.readAll(path, maxBytes: 65_536)
            XCTAssertEqual(freshPrefix, newBytes.prefix(65_536), "The live source must already serve the replacement")
            if middleOnly {
                XCTAssertGreaterThan(partialSize?.intValue ?? 0, changedRange.upperBound)
                let freshMiddle = OSAllocatedUnfairLock(initialState: Data())
                try await client.read(path, offset: Int64(changedRange.lowerBound), length: Int64(changedRange.count)) { bytes in
                    freshMiddle.withLock { $0.append(bytes) }
                    return true
                }
                XCTAssertEqual(freshMiddle.withLock { $0 }, newBytes[changedRange])
            }
            if whileDownloading {
                try await self.eventually { manager.jobs.first?.isActive == false }
                XCTAssertEqual(manager.jobs.first?.state, .failed)
                XCTAssertTrue(manager.jobs.first?.error?.contains("changed") == true)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "A mixed version must stay partial")
            }
            manager.retry(id)
            try await self.eventually { manager.jobs.first?.isActive == false }
            XCTAssertEqual(manager.jobs.first?.state, .done, manager.jobs.first?.error ?? "")
            XCTAssertEqual(manager.jobs.first?.totalBytes, Int64(newBytes.count))
            XCTAssertEqual(try Data(contentsOf: destination), newBytes, "An offline audiobook must not combine old and new samples")
            XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadPartial.metadataURL(for: partial).path))
        }
    }

    func testServiceLossWhileStreamingOffersRetryAndPreservesSeekPosition() async throws {
        let service = try FixtureServiceControl()
        try await service.setRunning(true)
        do {
            try await withLibrary { library, settings, _, book, _ in
                let player = PlayerEngine(library: library, settings: settings)
                defer { player.unload() }
                player.load(book, autoplay: true)
                try await self.eventually { player.isPlaying && player.currentTime > 0.5 || player.errorMessage != nil }
                XCTAssertNil(player.errorMessage)
                let stopped = try await service.setRunning(false)
                player.seek(toBookOffset: 150) // Beyond the small forward buffer, while the server is absent.
                try await self.eventually { player.errorMessage != nil }
                XCTAssertNotNil(player.errorMessage, "A broken source must offer Retry instead of hanging forever")
                XCTAssertFalse(player.isPlaying)
                XCTAssertEqual(player.currentTime, 150, accuracy: 1)
                let restarted = try await service.setRunning(true)
                XCTAssertGreaterThan(restarted.generation, stopped.generation)
                player.play()
                try await self.eventually { player.isPlaying && player.currentTime > 150.5 || player.errorMessage != nil }
                XCTAssertNil(player.errorMessage)
                XCTAssertTrue(player.isPlaying)
                XCTAssertGreaterThan(player.currentTime, 150.5)
            }
        } catch {
            _ = try? await service.setRunning(true)
            throw error
        }
    }

    func testLateRemoteReadFailureDoesNotInterruptANewLocalBook() async throws {
        let service = try FixtureServiceControl()
        try await service.setRunning(true)
        do {
            try await withLibrary { library, settings, _, remote, root in
                let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures")
                try FileManager.default.copyItem(at: fixtures.appending(path: "Audit Audio.wav"), to: root.appending(path: "Local Recovery.wav"))
                let source = LibrarySource(id: UUID(), kind: .folder, displayName: "Generated local recovery", addedAt: .now)
                let file = ScannedFile(relativePath: "Local Recovery.wav", fileSize: remote.totalBytes, modifiedAt: nil, metadata: AudioMetadata(duration: 180))
                let local = try XCTUnwrap(BookGrouper.group(.init(sourceID: source.id, sourceName: "Generated local recovery", files: [file], imagesByDirectory: [:])).first?.book)
                library.sources.append(source)
                library.resolvedRoots[source.id] = root
                library.books.append(local)
                let player = PlayerEngine(library: library, settings: settings)
                defer { player.unload() }
                player.load(remote, autoplay: true)
                try await self.eventually { player.isPlaying && player.currentTime > 0.5 || player.errorMessage != nil }
                XCTAssertNil(player.errorMessage)
                player.load(local, autoplay: true, startAt: BookPosition(trackIndex: 0, time: 45))
                try await service.setRunning(false) // Break old in-flight reads after the selection changes.
                try await self.eventually { player.isPlaying && player.currentTime > 45.5 || player.errorMessage != nil }
                try await Task.sleep(for: .seconds(2))
                XCTAssertEqual(player.book?.id, local.id)
                XCTAssertNil(player.errorMessage)
                XCTAssertTrue(player.isPlaying)
                XCTAssertGreaterThan(player.currentTime, 46)
                try await service.setRunning(true)
            }
        } catch {
            _ = try? await service.setRunning(true)
            throw error
        }
    }

    func testInterruptedSMBDownloadStaysPartialAndRetriesAfterSourceRecovery() async throws {
        try await withLibrary { library, _, client, originalBook, root in
            let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures")
            let remote = fixtures.appending(path: "Short Audio.wav")
            try FileManager.default.copyItem(at: fixtures.appending(path: "Audit Audio.wav"), to: remote)
            defer { try? FileManager.default.removeItem(at: remote) }
            let file = ScannedFile(relativePath: "Short Audio.wav", fileSize: originalBook.totalBytes, modifiedAt: nil,
                                   metadata: AudioMetadata(duration: 180))
            let book = try XCTUnwrap(BookGrouper.group(.init(sourceID: originalBook.sourceID, sourceName: "Local fixtures", files: [file], imagesByDirectory: [:])).first?.book)
            library.books.append(book)
            let destination = LibraryModel.documentsURL.appending(path: "Short Audio.wav")
            let partial = destination.appendingPathExtension("part")
            guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: partial.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: partial) }
            let manager = DownloadManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
            manager.download(book)
            try await self.eventually { manager.jobs.first?.doneBytes ?? 0 > 0 }
            let handle = try FileHandle(forWritingTo: remote)
            try handle.truncate(atOffset: 4 * 1024 * 1024)
            try handle.close()
            try await self.eventually { manager.jobs.first?.isActive == false }
            XCTAssertEqual(manager.jobs.first?.state, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            try FileManager.default.removeItem(at: remote)
            try FileManager.default.copyItem(at: fixtures.appending(path: "Audit Audio.wav"), to: remote)
            manager.retry(try XCTUnwrap(manager.jobs.first?.id))
            try await self.eventually { manager.jobs.first?.isActive == false }
            XCTAssertEqual(manager.jobs.first?.state, .done, manager.jobs.first?.error ?? "")
            XCTAssertEqual(Int64(try Data(contentsOf: destination).count), book.totalBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            try await self.eventually { library.localTwin(of: book) != nil }
        }
    }

    func testExpiredBackgroundBudgetPreservesQueueAndIgnoresStaleExpiration() async throws {
        try await exerciseExpiredBudget(resumeInForeground: false)
    }

    func testExpiredBackgroundBudgetResumesOnForeground() async throws {
        try await exerciseExpiredBudget(resumeInForeground: true)
    }

    func testForegroundBeforeExpiryKeepsLiveTransferRunning() async throws {
        try await exerciseExpiredBudget(resumeInForeground: true, foregroundBeforeExpiry: true)
    }

    private func exerciseExpiredBudget(resumeInForeground: Bool, foregroundBeforeExpiry: Bool = false) async throws {
        try await withLibrary { library, _, _, original, root in
            let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures")
            var books = [original]
            var remoteCopies: [URL] = []
            defer { for url in remoteCopies { try? FileManager.default.removeItem(at: url) } }
            for name in ["Queued Audio.wav", "Cancelled Audio.wav"] {
                let url = fixtures.appending(path: name)
                try FileManager.default.copyItem(at: fixtures.appending(path: "Audit Audio.wav"), to: url)
                remoteCopies.append(url)
                let file = ScannedFile(relativePath: name, fileSize: original.totalBytes, modifiedAt: nil, metadata: AudioMetadata(duration: 180))
                books.append(try XCTUnwrap(BookGrouper.group(.init(sourceID: original.sourceID, sourceName: "Local fixtures", files: [file], imagesByDirectory: [:])).first?.book))
            }
            library.books = books
            let destinations = books.map { LibraryModel.documentsURL.appending(path: $0.relativePath) }
            for url in destinations {
                guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: url.appendingPathExtension("part").path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            defer {
                for url in destinations { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("part")) }
            }
            let manager = DownloadManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
            for book in books { manager.download(book) }
            manager.cancel(try XCTUnwrap(manager.jobs.last?.id))
            let first = BackgroundTask()
            manager.runInBackground(first.execution)
            let stale = try XCTUnwrap(first.expiration)
            try await self.eventually { manager.jobs.first?.doneBytes ?? 0 > 0 }
            if foregroundBeforeExpiry {
                NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                XCTAssertEqual(first.completions, [false])
                stale()
                try await self.eventually { !manager.jobs.contains(where: \.isActive) }
            } else {
                first.expire()
                try await self.eventually { !first.completions.isEmpty && !manager.jobs.contains(where: { $0.state == .running }) }
                XCTAssertEqual(first.completions, [false])
                XCTAssertEqual(manager.jobs.map(\.state), [.queued, .queued, .cancelled])
                XCTAssertTrue(FileManager.default.fileExists(atPath: destinations[0].appendingPathExtension("part").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: destinations[0].path))
                if resumeInForeground {
                    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                    stale()
                    try await self.eventually { !manager.jobs.contains(where: \.isActive) }
                    XCTAssertEqual(first.completions, [false])
                } else {
                    let second = BackgroundTask()
                    manager.runInBackground(second.execution)
                    stale()
                    try await self.eventually { !second.completions.isEmpty }
                    XCTAssertEqual(second.completions, [true])
                    XCTAssertEqual(first.completions, [false])
                }
            }
            XCTAssertEqual(manager.jobs.map(\.state), [.done, .done, .cancelled])
            XCTAssertEqual(try Data(contentsOf: destinations[0]), try Data(contentsOf: fixtures.appending(path: "Audit Audio.wav")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinations[2].path))
        }
    }

}
