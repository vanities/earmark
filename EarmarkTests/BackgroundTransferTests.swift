import UIKit
import XCTest
@testable import Earmark

@MainActor
final class BackgroundTransferTests: XCTestCase {
    @MainActor private final class BackgroundTask {
        var expiration: (@Sendable () -> Void)?
        var completions: [Bool] = []
        lazy var execution = TransferBackgroundExecution(
            setExpirationHandler: { [weak self] in self?.expiration = $0 },
            complete: { [weak self] in self?.completions.append($0) })
        func expire() { expiration?() }
    }

    private func setup(jobs: [DownloadManager.Job]) throws -> (DownloadManager, LibraryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackgroundTransfers-\(UUID().uuidString)")
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "library")), settings: AppSettings(defaults: defaults))
        let store = LibraryStore(directory: root.appending(path: "queue"))
        try store.saveJSON(jobs, named: "transfers.json")
        return (DownloadManager(library: library, store: store, registersBackgroundTasks: false), store, root)
    }

    private func job(_ state: DownloadManager.Job.State) -> DownloadManager.Job {
        var job = DownloadManager.Job(id: UUID(), bookID: "missing-generated-fixture", title: "Generated fixture", totalBytes: 1024)
        job.state = state
        return job
    }

    func testSystemExpirationCompletesUnsuccessfullyAndKeepsPendingJobs() async throws {
        let (manager, _, _) = try setup(jobs: [job(.queued), job(.queued)])
        let task = BackgroundTask()
        manager.runInBackground(task.execution)
        task.expire()
        for _ in 0..<100 where task.completions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(task.completions, [false], "Expired system time must finish once as unsuccessful")
        XCTAssertFalse(manager.jobs.contains { $0.state == .cancelled }, "iOS interruption is not a user cancellation")
    }

    func testAnExplicitlyCancelledJobDoesNotRestartInBackground() async throws {
        let (manager, _, _) = try setup(jobs: [job(.cancelled)])
        let task = BackgroundTask()
        manager.runInBackground(task.execution)
        XCTAssertEqual(manager.jobs.first?.state, .cancelled)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.jobs.first?.state, .cancelled)
    }

    func testCancelOfRunningJobSurvivesQueueRestoration() async throws {
        let (manager, store, root) = try setup(jobs: [job(.queued)])
        let id = try XCTUnwrap(manager.jobs.first?.id)
        let background = BackgroundTask()
        manager.runInBackground(background.execution)
        manager.cancel(id)
        for _ in 0..<100 {
            if store.loadJSON([DownloadManager.Job].self, named: "transfers.json") == manager.jobs { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "restored-library")), settings: settings)
        let restored = DownloadManager(library: library, store: store, registersBackgroundTasks: false)
        XCTAssertEqual(restored.jobs.first?.state, .cancelled, "Relaunch must preserve explicit Cancel even before its worker exits")
        try await Task.sleep(for: .milliseconds(50))
    }
    func testQueueWrittenBeforeCancellationIntentFieldStillDecodes() throws {
        let id = UUID()
        let bytes = Data("""
        [{"id":"\(id.uuidString)","bookID":"legacy-fixture","title":"Legacy","kind":"download","totalBytes":1024,"doneBytes":128,"state":"cancelled"}]
        """.utf8)
        let jobs = try JSONDecoder().decode([DownloadManager.Job].self, from: bytes)
        let (manager, _, _) = try setup(jobs: jobs)
        XCTAssertEqual(manager.jobs.first?.id, id)
        XCTAssertEqual(manager.jobs.first?.state, .cancelled)
        XCTAssertEqual(manager.jobs.first?.doneBytes, 128)
    }

    func testCancelIntentIsOnDiskBeforeCancelReturns() throws {
        for _ in 0..<8 {
            let (manager, store, _) = try setup(jobs: [job(.queued)])
            let background = BackgroundTask()
            manager.runInBackground(background.execution)
            manager.cancel(try XCTUnwrap(manager.jobs.first?.id))
            let saved = store.loadJSON([DownloadManager.Job].self, named: "transfers.json")
            XCTAssertEqual(saved?.first?.cancellationRequested, true, "An immediate process exit must not lose explicit Cancel")
        }
    }

    func testForegroundTakesOverBeforeOldExpirationCanPauseWork() async throws {
        let (manager, _, _) = try setup(jobs: [job(.queued), job(.queued)])
        let task = BackgroundTask()
        manager.runInBackground(task.execution)
        let stale = try XCTUnwrap(task.expiration)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(task.completions, [false], "Foreground must end the old budget before accepting more work")
        stale()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(task.completions, [false], "The stale callback must not complete an already ended budget again")
    }

}
