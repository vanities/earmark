import SwiftUI
import ShelfKit

// An author's, a series' or a folder's page, laid out as Mango's series page: ShelfKit's
// `ShelfHeader` (the same view Mango draws), a ••• menu for the whole shelf, then the books.

/// The covers, what's here and how long it runs, and one button: resume the book you were on
/// here, or play the first one you haven't finished.
struct ShelfPageHeader: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    let title: String
    /// In the page's own order — the order "the first one you haven't finished" follows.
    let books: [Book]
    let openPlayer: () -> Void

    var body: some View {
        let bytes = books.reduce(Int64(0)) { $0 + $1.totalBytes }
        ShelfHeader(title: title, subtitle: subtitle, detail: bytes > 0 ? bytes.byteCountString : nil, primary: primary) {
            ShelfCover(books: books)
        }
    }

    /// "5 books · 62h 10m · 2 finished".
    private var subtitle: String {
        var parts = [books.count == 1 ? "1 book" : "\(books.count) books"]
        let duration = books.reduce(0) { $0 + $1.totalDuration }
        if duration > 0 { parts.append(duration.shortDurationString) }
        let finished = books.count { library.progress(for: $0.id).isFinished }
        if finished > 0 { parts.append("\(finished) finished") }
        return parts.joined(separator: " · ")
    }

    private var primary: ShelfHeader<ShelfCover>.Primary? {
        guard let next = NextUp.pick(in: books, progress: { library.progress(for: $0) }) else { return nil }
        if player.book?.id == next.book.id, player.isPlaying {
            return .init("Now Playing", systemImage: "waveform") { openPlayer() }
        }
        return .init("\(next.resuming ? "Resume" : "Play") \(next.book.title)", systemImage: "play.fill") {
            player.load(next.book, autoplay: true)
            openPlayer()
        }
    }
}

/// One book's cover, or the first three stacked — the stack the Library's row showed, larger.
struct ShelfCover: View {
    let books: [Book]

    var body: some View {
        if books.count == 1, let book = books.first {
            ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
        } else {
            CoverStack(books: books, size: ShelfHeader<EmptyView>.coverWidth)
        }
    }
}

/// The whole shelf at once, as Mango's series menu has it: download what's only on the NAS, or
/// give back the space its downloads take (they play from the NAS again). Only what applies is
/// offered, and nothing on a page with neither.
struct ShelfPageMenu: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    /// "Author", "Series", "Folder" — what VoiceOver calls the button.
    let name: String
    let books: [Book]

    var body: some View {
        let onlyOnNAS = books.filter { library.isRemote($0) && !(downloads.job(for: $0.id)?.isActive ?? false) }
        // Not the one playing: it keeps its file until it stops (the book menu's rule).
        let downloaded = books.compactMap { library.downloadedCopy(of: $0) }
            .filter { !(player.isPlaying && player.book?.id == $0.id) }
        if !onlyOnNAS.isEmpty || !downloaded.isEmpty {
            Menu {
                if !onlyOnNAS.isEmpty {
                    Button("Download All (\(onlyOnNAS.count))", systemImage: "arrow.down.circle") {
                        onlyOnNAS.forEach(downloads.download)
                    }
                }
                if !downloaded.isEmpty {
                    Button("Remove Downloads (\(downloaded.reduce(Int64(0)) { $0 + $1.totalBytes }.byteCountString))",
                           systemImage: "trash") {
                        player.removeDownloads(downloaded, in: library)
                    }
                }
            } label: {
                Label(name, systemImage: "ellipsis.circle")
            }
        }
    }
}

/// A series' or a folder's page: the header, then its books in the Library's grid or list.
struct GroupShelfView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    let group: LibraryGroup
    let openPlayer: () -> Void

    var body: some View {
        let shelf = library.live(group)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ShelfPageHeader(title: shelf.title, books: shelf.books, openPlayer: openPlayer)
                BookGridSection(title: "Books", books: shelf.books, layout: settings.libraryLayout)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle(shelf.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShelfPageMenu(name: group.id.hasPrefix("folder:") ? "Folder" : "Series", books: shelf.books)
            }
        }
    }
}
