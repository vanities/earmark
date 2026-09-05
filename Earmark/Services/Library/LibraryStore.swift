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
        var current = loadJSON(LibraryState.self, named: Self.libraryFile) ?? LibraryState()
        // An older build may have moved the library aside as ".corrupt-*" because it couldn't decode
        // a newer field (that is what cost a test library its NAS server). Merge any such file's user
        // state back in — current always wins — and rename it so it is only ever considered once.
        let salvaged = salvageMovedAsideLibraries()
        guard !salvaged.isEmpty else { return current }
        let before = (current.sources.count, current.nasServers.count, current.progress.count, current.customArtwork.count)
        for old in salvaged { current.merge(restoring: old) }
        let after = (current.sources.count, current.nasServers.count, current.progress.count, current.customArtwork.count)
        if before != after {
            Logger.store.warning("[store] restored moved-aside data: sources \(before.0)→\(after.0), nas \(before.1)→\(after.1), progress \(before.2)→\(after.2), covers \(before.3)→\(after.3)")
            try? saveLibrary(current)
        }
        return current
    }

    /// Decodes every `library.json.corrupt-*` this build can read (newest first) and renames each one
    /// away from the `.corrupt-` prefix so a later launch never reconsiders it: `.recovered-` when it
    /// decoded, `.unreadable-` when it did not.
    private func salvageMovedAsideLibraries() -> [LibraryState] {
        let prefix = "\(Self.libraryFile).corrupt-"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .sorted(by: >)
        guard !names.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var salvaged: [LibraryState] = []
        for name in names {
            let url = directory.appending(path: name)
            do {
                let state = try decoder.decode(LibraryState.self, from: Data(contentsOf: url))
                Logger.store.warning("[store] salvaged \(name, privacy: .public): sources=\(state.sources.count) nas=\(state.nasServers.count) progress=\(state.progress.count)")
                if state.hasUserData { salvaged.append(state) }
                rename(url, name: name, replacing: ".corrupt-", with: ".recovered-")
            } catch {
                Logger.store.error("[store] \(name, privacy: .public) still unreadable: \(error.localizedDescription, privacy: .public)")
                rename(url, name: name, replacing: ".corrupt-", with: ".unreadable-")
            }
        }
        return salvaged
    }

    private func rename(_ url: URL, name: String, replacing old: String, with new: String) {
        let dest = directory.appending(path: name.replacingOccurrences(of: old, with: new))
        try? FileManager.default.moveItem(at: url, to: dest)
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
