import Foundation
import os

/// JSON-on-disk persistence in Application Support. Small, inspectable, and it never
/// throws away the user's data: a corrupt file is moved aside instead of crashing.
struct LibraryStore: Sendable {
    let directory: URL

    static let libraryFile = "library.json"
    static let metadataCacheFile = "metadata-cache.json"
    static let fingerprintsFile = "fingerprints.json"

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appending(path: "Earmark", directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: Library

    func loadLibrary() -> LibraryState {
        loadJSON(LibraryState.self, named: Self.libraryFile) ?? LibraryState()
    }

    func saveLibrary(_ state: LibraryState) throws {
        try saveJSON(state, named: Self.libraryFile)
    }

    // MARK: Generic JSON

    func loadJSON<T: Decodable>(_ type: T.Type, named name: String) -> T? {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.store.info("[store] no \(name, privacy: .public) yet")
            return nil
        }
        let sw = Stopwatch()
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(T.self, from: data)
            Logger.store.info("[store] loaded \(name, privacy: .public) bytes=\(data.count) in \(sw.ms, format: .fixed(precision: 1))ms")
            return value
        } catch {
            Logger.store.error("[store] failed to load \(name, privacy: .public): \(error.localizedDescription, privacy: .public) — moving aside")
            let backup = directory.appending(path: "\(name).corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }

    func saveJSON<T: Encodable>(_ value: T, named name: String) throws {
        let sw = Stopwatch()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: directory.appending(path: name), options: .atomic)
        Logger.store.debug("[store] saved \(name, privacy: .public) bytes=\(data.count) in \(sw.ms, format: .fixed(precision: 1))ms")
    }
}
