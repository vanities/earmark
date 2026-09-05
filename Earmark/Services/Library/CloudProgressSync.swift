import Foundation
import os

/// Thin wrapper over iCloud key-value storage that holds one JSON blob of progress keyed by
/// `Book.syncKey`. No-ops safely when the iCloud entitlement isn't present (device builds before
/// the capability is enabled), so it never crashes — it just doesn't sync there.
@MainActor
final class CloudProgressSync {
    private let store = NSUbiquitousKeyValueStore.default
    private static let key = "progress.v1"
    private static let maxBytes = 900_000  // KVS caps a value near 1 MB; stay under it.
    private var observer: (any NSObjectProtocol)?
    /// Called when another device changes the store.
    var onExternalChange: (() -> Void)?

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onExternalChange?() }
        }
        store.synchronize()
    }

    func load() -> [String: PlaybackProgress] {
        guard let data = store.data(forKey: Self.key) else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: PlaybackProgress].self, from: data)) ?? [:]
    }

    func save(_ snapshot: [String: PlaybackProgress]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        guard data.count <= Self.maxBytes else {
            Logger.store.error("[cloud] progress snapshot \(data.count) bytes exceeds KVS limit — not syncing")
            return
        }
        store.set(data, forKey: Self.key)
        store.synchronize()
    }
}
