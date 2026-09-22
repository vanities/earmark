import SwiftUI
import os

/// Pick books on one source to move in bulk, a compact row each under its author: on a NAS,
/// download them or give the space back and play from the NAS again; on this iPhone, upload
/// them to the NAS or remove the downloads. The buttons say what a tap will do, and how much.
struct SelectBooksView: View {
    let source: LibrarySource

    @Environment(LibraryModel.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()

    var body: some View {
        // Every book here, downloaded ones included: the library shows a download in place of
        // its NAS copy, but this is where it can go back.
        let books = library.books.filter { $0.sourceID == source.id && !library.hiddenBookIDs.contains($0.id) }
        let status = Status(library: library, downloads: downloads)
        let actionable = Set(books.filter { action(for: $0, status) != nil }.map(\.id))
        let picked = books.filter { selection.contains($0.id) }
        NavigationStack {
            List(selection: $selection) {
                Section { summary(books, status) }
                ForEach(blocks(books)) { block in
                    Section {
                        ForEach(block.books) { book in
                            row(book, showsAuthor: block.author == nil, status)
                                .tag(book.id)
                                .selectionDisabled(action(for: book, status) == nil)
                        }
                    } header: {
                        if let author = block.author {
                            authorHeader(author, ids: Set(block.books.map(\.id)).intersection(actionable))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 36)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(selection.isEmpty ? "Select Books" : "\(selection.count) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(!actionable.isEmpty && actionable.isSubset(of: selection) ? "Deselect All" : "Select All") {
                        selection = actionable.isSubset(of: selection) ? [] : actionable
                    }
                    .disabled(actionable.isEmpty)
                }
                bottomBar(picked, status)
            }
        }
    }

    // MARK: Where things stand

    /// Where every book stands, worked out once per update rather than once per row.
    private struct Status {
        /// Downloads still on a NAS, by `syncKey`.
        let pairs: [String: DownloadPair]
        /// Every NAS book, by `syncKey`.
        let onNAS: Set<String>
        /// Transfers queued or under way, by book id.
        let jobs: [String: DownloadManager.Job]

        @MainActor init(library: LibraryModel, downloads: DownloadManager) {
            pairs = library.downloadPairs()
            onNAS = Set(library.books.filter { library.isRemote($0) }.map(\.syncKey))
            jobs = Dictionary(downloads.jobs.filter(\.isActive).map { ($0.bookID, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    private enum Place: Equatable {
        /// Only on the NAS.
        case remote
        /// Coming down or going up, this far along.
        case moving(Double)
        /// On this iPhone and on the NAS.
        case both
        /// Only on this iPhone.
        case deviceOnly
    }

    private enum Action { case download, upload, remove }

    private func place(of book: Book, _ status: Status) -> Place {
        if let job = status.jobs[book.id] { return .moving(job.fraction) }
        if source.kind == .smb { return status.pairs[book.syncKey] != nil ? .both : .remote }
        return status.onNAS.contains(book.syncKey) ? .both : .deviceOnly
    }

    /// What a bulk action would do to a book, if anything. A download only goes while it isn't
    /// playing, and only from Earmark's own folder: a picked folder's books can go up to the
    /// NAS, but Earmark never deletes them.
    private func action(for book: Book, _ status: Status) -> Action? {
        switch place(of: book, status) {
        case .remote: return .download
        case .deviceOnly: return downloads.mirrorServerID == nil ? nil : .upload
        case .moving: return nil
        case .both:
            guard let pair = status.pairs[book.syncKey] else { return nil }
            return player.isPlaying && player.book?.id == pair.download.id ? nil : .remove
        }
    }

    private func books(_ books: [Book], for action: Action, _ status: Status) -> [Book] {
        books.filter { self.action(for: $0, status) == action }
    }

    private static func bytes(_ books: [Book]) -> String {
        books.reduce(Int64(0)) { $0 + $1.totalBytes }.byteCountString
    }

    /// A run of the list: an author's books under their name, or single books between them.
    private struct Block: Identifiable {
        let id: String
        let author: String?
        var books: [Book]
    }

    /// Authors in name order. One with several books gets a header (and Select All); a lone
    /// book joins its neighbours in a run with its author on the row — a header per book made
    /// the list twice as tall.
    private func blocks(_ books: [Book]) -> [Block] {
        let authors = Dictionary(grouping: books, by: \.displayAuthor)
            .map { (name: $0.key, books: library.sorted($0.value, by: .title)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var blocks: [Block] = []
        for author in authors {
            if author.books.count > 1 {
                blocks.append(Block(id: "author|" + author.name, author: author.name, books: author.books))
            } else if let last = blocks.indices.last, blocks[last].author == nil {
                blocks[last].books += author.books
            } else {
                blocks.append(Block(id: "run|" + author.name, author: nil, books: author.books))
            }
        }
        return blocks
    }

    // MARK: Rows

    private func summary(_ books: [Book], _ status: Status) -> some View {
        let both = books.filter { place(of: $0, status) == .both }
        let total = books.reduce(Int64(0)) { $0 + $1.totalBytes }, bothBytes = both.reduce(Int64(0)) { $0 + $1.totalBytes }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(source.kind == .smb ? "On this iPhone" : "On the NAS")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(both.isEmpty ? "None of \(books.count) · \(total.byteCountString)"
                     : "\(both.count) of \(books.count) · \(bothBytes.byteCountString) of \(total.byteCountString)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: total > 0 ? Double(bothBytes) / Double(total) : 0)
                .tint(.accentColor)
        }
        .padding(.vertical, 2)
        .selectionDisabled()
    }

    private func authorHeader(_ name: String, ids: Set<String>) -> some View {
        HStack {
            Text(name)
            Spacer()
            if ids.count > 1 {
                Button(ids.isSubset(of: selection) ? "Deselect" : "Select All") {
                    if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
                }
                .font(.caption.weight(.semibold))
                .textCase(nil)
            }
        }
    }

    private func row(_ book: Book, showsAuthor: Bool, _ status: Status) -> some View {
        let place = place(of: book, status)
        return HStack(spacing: 10) {
            ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 4)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(book, showsAuthor: showsAuthor))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            badge(place)
        }
        .opacity(action(for: book, status) == nil && place != .both ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue(place))
    }

    /// "Herman Melville · 1.2 GB · 11h 32m", "1.2 GB · 11h 32m · Book 3" under its author.
    private func detail(_ book: Book, showsAuthor: Bool) -> String {
        var parts = (showsAuthor ? [book.displayAuthor] : []) + [book.totalBytes.byteCountString, book.totalDuration.shortDurationString]
        if let index = book.seriesIndex { parts.append("Book \(BookDetailView.format(index))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func badge(_ place: Place) -> some View {
        switch place {
        case .moving(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
        // Filled for "already there", outlined for "could go" — never a check, which reads as
        // the row being selected.
        case .both:
            Image(systemName: source.kind == .smb ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .remote:
            Image(systemName: "arrow.down.circle").foregroundStyle(.tertiary)
        case .deviceOnly:
            Image(systemName: downloads.mirrorServerID == nil ? "iphone" : "arrow.up.circle").foregroundStyle(.tertiary)
        }
    }

    private func accessibilityValue(_ place: Place) -> String {
        switch place {
        case .remote: "Only on the NAS"
        case .moving(let fraction): "\(source.kind == .smb ? "Downloading" : "Uploading"), \(Int(fraction * 100)) percent"
        case .both: source.kind == .smb ? "On this iPhone" : "Also on the NAS"
        case .deviceOnly: "Only on this iPhone"
        }
    }

    // MARK: Actions

    @ToolbarContentBuilder
    private func bottomBar(_ picked: [Book], _ status: Status) -> some ToolbarContent {
        let toDownload = books(picked, for: .download, status)
        let toUpload = books(picked, for: .upload, status)
        let toRemove = books(picked, for: .remove, status)
        ToolbarItemGroup(placement: .bottomBar) {
            // Words with a count and a size: the bottom bar draws an icon-only label as a bare glyph.
            if source.kind == .smb {
                Button { download(toDownload) } label: {
                    Text(toDownload.isEmpty ? "Download" : "Download \(toDownload.count) (\(Self.bytes(toDownload)))")
                }
                .disabled(toDownload.isEmpty)
            } else if downloads.mirrorServerID != nil {
                Button { upload(toUpload) } label: {
                    Text(toUpload.isEmpty ? "Upload" : "Upload \(toUpload.count) (\(Self.bytes(toUpload)))")
                }
                .disabled(toUpload.isEmpty)
            }
            Spacer()
            if source.kind == .smb || source.kind == .appDocuments {
                Button(role: .destructive) { remove(toRemove, status) } label: {
                    Text(toRemove.isEmpty ? "Remove" : "Remove \(toRemove.count) (\(Self.bytes(toRemove)))")
                }
                .disabled(toRemove.isEmpty)
            }
        }
    }

    private func download(_ books: [Book]) {
        for book in library.sorted(books, by: .author) { downloads.download(book) }
        Logger.downloads.info("[downloads] queued \(books.count) from a selection in \(source.displayName, privacy: .public)")
        selection.removeAll()
    }

    private func upload(_ books: [Book]) {
        guard let server = downloads.mirrorServerID else { return }
        for book in library.sorted(books, by: .author) { downloads.mirror(book, to: server) }
        Logger.downloads.info("[downloads] queued \(books.count) uploads from a selection in \(source.displayName, privacy: .public)")
        selection.removeAll()
    }

    private func remove(_ books: [Book], _ status: Status) {
        player.removeDownloads(books.compactMap { status.pairs[$0.syncKey]?.download }, in: library)
        selection.removeAll()
    }
}
