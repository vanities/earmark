import SwiftUI
import ShelfKit

struct LibraryBackupView: View {
    @Environment(LibraryModel.self) private var library
    var body: some View {
        BackupRestoreView(app: "Earmark", export: export, preview: preview, restore: restore)
    }
    private func export() async throws -> LibraryBackupDocument {
        var state = library.snapshot()
        state.nasServers = []
        for i in state.sources.indices { state.sources[i].bookmark = nil }
        let coverIDs = Set(state.customArtwork.values)
        let images = await Task.detached(priority: .utility) {
            var images: [String: Data] = [:]
            for id in coverIDs {
                if let data = ArtworkStore.shared.image(for: id)?.jpegData(compressionQuality: 0.9) { images[id] = data }
            }
            return images
        }.value
        return try LibraryBackupDocument(app: "Earmark", state: JSONEncoder().encode(state), covers: images)
    }
    private func decode(_ backup: LibraryBackupDocument) throws -> LibraryState {
        try backup.validate(app: "Earmark")
        let state = try JSONDecoder().decode(LibraryState.self, from: backup.state)
        guard state.customArtwork.values.allSatisfy(LibraryBackupDocument.safeCoverID) else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }
    private func preview(_ backup: LibraryBackupDocument) throws -> String {
        let old = try decode(backup)
        var proposed = library.snapshot()
        proposed.preparePortableGrouping(old)
        let matches = proposed.portableMatches(old)
        let matchedIDs = Set(matches.map { $0.0 })
        let matchedKeys = Set(old.books.filter { matchedIDs.contains($0.id) }.map(\.syncKey))
        let savedKeys = Set(old.books.map(\.syncKey))
        let skipped = old.books.filter { !matchedKeys.contains($0.syncKey) }.map(\.title)
        var summary = "\(matchedKeys.count) of \(savedKeys.count) saved books match this library. \(old.bookLists.count) lists and \(backup.covers.count) cover images in this backup."
        let arrangements = proposed.manualGroupings.count - library.manualGroupings.count
        if arrangements > 0 { summary += " \(arrangements) saved track arrangement(s) will be restored on untouched books." }
        if !skipped.isEmpty { summary += "\n\nSkipped: " + skipped.prefix(30).joined(separator: ", ") }
        return summary
    }
    private func restore(_ backup: LibraryBackupDocument) async throws {
        var old = try decode(backup)
        let valid = Set(old.customArtwork.values)
        for (id, data) in backup.covers where valid.contains(id) {
            if !ArtworkStore.shared.hasImage(id: id), !ArtworkStore.shared.store(imageData: data, id: id) { throw CocoaError(.fileWriteUnknown) }
        }
        // Never retain a reference to an image absent from the portable bundle/device.
        old.customArtwork = old.customArtwork.filter { ArtworkStore.shared.hasImage(id: $0.value) }
        library.restorePortable(old)
    }
}
