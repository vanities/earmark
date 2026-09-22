import Foundation
import ShelfKit

/// Earmark's JSON files in Application Support/Earmark, through ShelfKit's `JSONStore` (shared
/// with Mango): a file it can't read is moved aside, never lost, and a library an older build
/// moved aside is merged back once this build can read it.
struct LibraryStore: Sendable {
    private let json: JSONStore

    static let libraryFile = "library.json"
    static let metadataCacheFile = "metadata-cache.json"
    static let fingerprintsFile = "fingerprints.json"

    var directory: URL { json.directory }

    init(directory: URL? = nil) {
        json = JSONStore(appFolder: "Earmark", directory: directory)
    }

    func loadLibrary() -> LibraryState {
        json.loadLibrary(LibraryState.self, named: Self.libraryFile)
    }

    func saveLibrary(_ state: LibraryState) throws {
        try json.saveJSON(state, named: Self.libraryFile)
    }

    func loadJSON<T: Decodable>(_ type: T.Type, named name: String) -> T? {
        json.loadJSON(type, named: name)
    }

    func saveJSON<T: Encodable>(_ value: T, named name: String) throws {
        try json.saveJSON(value, named: name)
    }
}

extension LibraryState: SalvageableLibrary {
    /// An empty library (the store's starting point when there's no file yet).
    init() { self.init(sources: []) }

    /// What a restore log line compares, as the store's own logging did before it was shared.
    var salvageCounts: [String: Int] {
        ["sources": sources.count, "nas": nasServers.count, "progress": progress.count, "covers": customArtwork.count]
    }
}
