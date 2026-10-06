import SwiftUI
import ShelfKit

struct OfflineLibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var revision = 0

    private var upcoming: [Book] {
        let candidates = (player.book.map { [$0] } ?? []) + player.queueKeys.compactMap { player.queuedBook(for: $0) } + library.inProgressBooks.flatMap { [$0] + [library.nextInSeries(after: $0)].compactMap { $0 } }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.syncKey).inserted }
    }
    private var others: [Book] {
        let keys = Set(upcoming.map(\.syncKey))
        return library.visibleBooks.filter { !keys.contains($0.syncKey) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func matching(_ items: [Book]) -> [Book] {
        library.search(query, in: items)
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Checks the files on this device. Download anything you need before leaving your network. Files managed by another app may need Keep Downloaded in Files.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !matching(upcoming).isEmpty {
                    Section("Up next") { rows(matching(upcoming)) }
                }
                Section("Library") { rows(matching(others)) }
            }
            .searchable(text: $query, prompt: "Find a book")
            .navigationTitle("Ready for offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Check again", systemImage: "arrow.clockwise") { revision += 1 } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
    private func rows(_ items: [Book]) -> some View {
        ForEach(items) { item in OfflineBookRow(book: item).id("\(item.id)-\(revision)") }
    }
}

private struct OfflineBookRow: View {
    @Environment(LibraryModel.self) private var library
    @Environment(DownloadManager.self) private var downloads
    let book: Book
    @State private var status: OfflineReadiness?
    private var remote: Bool { library.isRemote(book) }
    private var downloadSource: Book? { library.nasCopy(of: book) }
    private var active: Bool { downloadSource.map { source in downloads.jobs.contains { $0.bookID == source.id && $0.isActive } } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OfflineReadinessRow(title: book.title, status: status)
            BookCreditsView(book: book)
            if let source = downloadSource, remote || status == .unavailable {
                Button(active ? "Downloading…" : "Download", systemImage: "arrow.down.circle") { downloads.download(source) }
                    .disabled(active)
            }
        }
        .task(id: book) { status = await check() }
    }
    private func check() async -> OfflineReadiness {
        if remote { return .needsDownload }
        // A partially scanned download may omit missing tracks; use the NAS manifest when available.
        let tracks = library.nasCopy(of: book)?.tracks ?? book.tracks
        let files = tracks.compactMap { track in
            library.url(forTrack: track, in: book).map { OfflineReadiness.File(url: $0, expectedBytes: track.fileSize) }
        }
        guard files.count == tracks.count else { return .unavailable }
        let managed = library.source(for: book)?.kind == .appDocuments
        return await Task.detached(priority: .utility) {
            OfflineReadiness.check(files: files, managedCopy: managed)
        }.value
    }
}
