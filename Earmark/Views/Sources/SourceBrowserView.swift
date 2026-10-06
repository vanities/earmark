import SwiftUI
import os
import ShelfKit

/// Everything on one source, a compact row per book under its author, drawn as Mango draws its
/// sources: how much is in both places (on a NAS, how much is on this iPhone; on this iPhone,
/// how much is safe on the NAS), and a ring per book with what it can do — download it, upload
/// it, give the space back, or move it in. Select picks any mix; the bottom bar says what a tap
/// will do, and how much.
struct SourceBrowserView: View {
    let source: LibrarySource

    @Environment(LibraryModel.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerEngine.self) private var player
    @Environment(RootChrome.self) private var chrome
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var opened: Book?
    /// The whole-source actions ask first, as they do from a swipe on the Sources list.
    @State private var syncing: LibrarySource?
    @State private var mirroring: LibrarySource?
    @State private var movingAll: LibrarySource?
    /// A move asks first: the originals leave the folder the user picked.
    @State private var confirmingMove: [Book]?

    var body: some View {
        let books = self.books
        let status = Status(library: library, downloads: downloads)
        let unsupported = library.unsupportedFiles[source.id] ?? []
        List {
            Section { summary(books, status) }
            if books.isEmpty {
                ContentUnavailableView("No Books Here", systemImage: "folder", description: Text(source.kind == .appDocuments
                    ? "Move audiobooks into \(DeviceStorage.earmarkFolder) using the Files app."
                    : "No playable audio files were found here."))
            }
            ForEach(blocks(books)) { block in
                Section {
                    ForEach(block.books) { book in
                        row(book, showsAuthor: block.author == nil, status)
                    }
                } header: {
                    if let author = block.author { authorHeader(author, block.books, status) }
                }
            }
            if !unsupported.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(unsupported, id: \.self) { path in
                            Text(path).font(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        Label("\(unsupported.count) file\(unsupported.count == 1 ? "" : "s") iOS can't play (.ogg/.wma/.opus)",
                              systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .environment(\.defaultMinListRowHeight, 36)
        .navigationTitle(selecting ? (selection.isEmpty ? "Select Books" : "\(selection.count) Selected") : title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)
        // The selection's actions live in the bottom bar; the floating tab bar and the mini player
        // would sit on them.
        .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
        .onChange(of: selecting) { _, selecting in chrome.hidesMiniPlayer = selecting }
        .onDisappear { chrome.hidesMiniPlayer = false }
        .toolbar { toolbar(books, status) }
        .navigationDestination(item: $opened) { BookDetailView(book: $0, openPlayer: {}) }
        .syncConfirmation(source: $syncing)
        .mirrorConfirmation(source: $mirroring)
        .moveConfirmation(source: $movingAll)
        .confirmationDialog(
            "Move \(confirmingMove?.count ?? 0) into Earmark?",
            isPresented: Binding(get: { confirmingMove != nil }, set: { if !$0 { confirmingMove = nil } }),
            titleVisibility: .visible, presenting: confirmingMove
        ) { books in
            Button("Move \(books.count) (\(Self.bytes(books)))") { move(books) }
        } message: { _ in
            Text("Each is copied into \(DeviceStorage.earmarkFolder), checked, and only then removed from \(source.displayName). Your place, bookmarks and corrections go with them. A different file already in Earmark's folder is never replaced.")
        }
    }

    private var title: String {
        source.kind == .appDocuments ? DeviceStorage.name : source.displayName
    }

    /// Every book here, downloads included: the library shows a download in place of its NAS
    /// copy, but this is where it can go back.
    private var books: [Book] {
        library.books.filter { $0.sourceID == source.id && !library.hiddenBookIDs.contains($0.id) }
    }

    private var serverName: String {
        downloads.mirrorServerID.flatMap { library.server(id: $0)?.name } ?? "NAS"
    }

    /// Where this source lives: a NAS share, or the folder on this iPhone.
    private var location: String? {
        if let server = source.serverID.flatMap({ library.server(id: $0) }) { return server.displayLocation }
        return library.rootURL(for: source.id)?.path(percentEncoded: false)
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

    private enum Action { case download, upload, remove }

    private func place(of book: Book, _ status: Status) -> CopyPlace {
        if let job = status.jobs[book.id] { return .transferring(job.fraction) }
        if source.kind == .smb { return status.pairs[book.syncKey] != nil ? .both : .remote }
        return status.onNAS.contains(book.syncKey) ? .both : .deviceOnly
    }

    /// What Download, Upload or Remove would do to a book, if anything. Only a download is ever
    /// removed — from a NAS's page or Earmark's own folder, never a folder the user picked — and
    /// not while it's playing.
    private func action(for book: Book, _ status: Status) -> Action? {
        switch place(of: book, status) {
        case .remote: return .download
        case .deviceOnly: return downloads.mirrorServerID == nil ? nil : .upload
        case .transferring: return nil
        case .both:
            guard source.kind == .smb || source.kind == .appDocuments, let pair = status.pairs[book.syncKey] else { return nil }
            return player.isPlaying && player.book?.id == pair.download.id ? nil : .remove
        }
    }

    private func books(_ books: [Book], for action: Action, _ status: Status) -> [Book] {
        books.filter { self.action(for: $0, status) == action }
    }

    /// A folder the user picked can be moved into Earmark's own — only when they ask.
    private var canMove: Bool { source.kind == .folder }

    private func movable(_ books: [Book], _ status: Status) -> [Book] {
        guard canMove else { return [] }
        return books.filter { status.jobs[$0.id] == nil }
    }

    /// Something a bulk action can do to it: download, upload, remove — or move, from a folder.
    private func isSelectable(_ book: Book, _ status: Status) -> Bool {
        action(for: book, status) != nil || (canMove && status.jobs[book.id] == nil)
    }

    private static func bytes(_ books: [Book]) -> String {
        books.reduce(Int64(0)) { $0 + $1.totalBytes }.byteCountString
    }

    /// How much of `books` is in both places by size, counting what's on its way.
    private func bothFraction(_ books: [Book], _ status: Status) -> Double {
        let total = books.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return 0 }
        let both = books.reduce(Int64(0)) { sum, book in
            switch place(of: book, status) {
            case .both: sum + book.totalBytes
            case .transferring: sum + (status.jobs[book.id]?.doneBytes ?? 0)
            case .remote, .deviceOnly: sum
            }
        }
        return Double(both) / Double(total)
    }

    // MARK: Authors

    /// A run of the list: an author's books under their name, or single books between them.
    private struct Block: Identifiable {
        let id: String
        let author: String?
        var books: [Book]
    }

    /// Authors in name order. One with several books gets a header; a lone book joins its
    /// neighbours in a run with its author on the row — a header per book made the list twice
    /// as tall.
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

    private func authorHeader(_ name: String, _ books: [Book], _ status: Status) -> some View {
        let ids = Set(books.filter { isSelectable($0, status) }.map(\.id))
        return HStack {
            Text(name)
            Spacer()
            if selecting, ids.count > 1 {
                Button(ids.isSubset(of: selection) ? "Deselect" : "Select All") {
                    if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
                }
                .font(.caption.weight(.semibold))
                .textCase(nil)
            }
        }
    }

    // MARK: Summary

    private func summary(_ books: [Book], _ status: Status) -> some View {
        let both = books.filter { place(of: $0, status) == .both }
        let total = Self.bytes(books)
        let tracksNAS = source.kind == .smb || !status.onNAS.isEmpty || downloads.mirrorServerID != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(!tracksNAS ? "\(books.count) book\(books.count == 1 ? "" : "s")" : source.kind == .smb ? "On this \(DeviceStorage.device)" : "On the NAS")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(!tracksNAS ? total
                     : both.isEmpty ? "None of \(books.count) · \(total)"
                     : "\(both.count) of \(books.count) · \(Self.bytes(both)) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if tracksNAS {
                StorageBar(fraction: bothFraction(books, status))
                HStack(spacing: 14) {
                    PlaceLegend(.both, source.kind == .smb ? "On this \(DeviceStorage.device)" : "Also on the NAS")
                    PlaceLegend(source.kind == .smb ? .remote : .deviceOnly, source.kind == .smb ? "Only on the NAS" : "Only on this \(DeviceStorage.device)")
                }
            }
            if let location {
                Text(location)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Books

    private func row(_ book: Book, showsAuthor: Bool, _ status: Status) -> some View {
        let place = place(of: book, status)
        let picked = selection.contains(book.id)
        let selectable = isSelectable(book, status)
        return HStack(spacing: 10) {
            if selecting {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 36)
                    .opacity(selectable ? 1 : 0.35)
                    .accessibilityHidden(true)
            }
            ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 4)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(book, showsAuthor: showsAuthor, place))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let narrator = book.narratorCredit {
                    Text(narrator).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selecting && picked ? [.isButton, .isSelected] : .isButton)
            Spacer(minLength: 4)
            if !selecting {
                ringButton(book, place, status)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                guard selectable else { return }
                if picked { selection.remove(book.id) } else { selection.insert(book.id) }
            } else {
                // A NAS book that's downloaded opens the copy on this iPhone, which plays offline.
                opened = status.pairs[book.syncKey]?.download ?? book
            }
        }
        .opacity(selecting && !selectable ? 0.5 : 1)
        .contextMenu { if !selecting { BookContextMenu(book: book) } }
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
    }

    /// "On this iPhone · 1.2 GB · 11h 32m", "Herman Melville · 1.2 GB · 11h 32m · Book 3".
    private func detail(_ book: Book, showsAuthor: Bool, _ place: CopyPlace) -> String {
        var parts: [String] = []
        switch place {
        case .transferring(let fraction): parts.append("\(source.kind == .smb ? "Downloading" : "Uploading") \(Int(fraction * 100))%")
        case .both where source.kind == .smb: parts.append("On this \(DeviceStorage.device)")
        default: break
        }
        if showsAuthor { parts.append(book.displayAuthor) }
        parts += [book.totalBytes.byteCountString, book.totalDuration.shortDurationString]
        if let index = book.seriesIndex { parts.append("Book \(BookDetailView.format(index))") }
        return parts.joined(separator: " · ")
    }

    /// A book's one-tap control: a ring of where it stands, with a menu of what it can do.
    @ViewBuilder
    private func ringButton(_ book: Book, _ place: CopyPlace, _ status: Status) -> some View {
        let moving: Bool = if case .transferring = place { true } else { false }
        let action = action(for: book, status)
        let canMoveIn = canMove && status.jobs[book.id] == nil
        if moving || action != nil || canMoveIn {
            Menu {
                actions(book, action, status)
            } label: {
                Group {
                    if canMoveIn, action == nil, !moving {
                        Image(systemName: "arrow.right.circle").font(.title3).foregroundStyle(Color.accentColor)
                    } else {
                        TransferRing(fraction: place == .both ? 1 : { if case .transferring(let f) = place { f } else { 0 } }(),
                                     upward: source.kind != .smb, isMoving: moving, isComplete: place == .both)
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(source.kind == .smb ? "Download options" : "Transfer options")
        } else if place == .both {
            TransferRing(fraction: 1, upward: false, isMoving: false, isComplete: true)
                .frame(width: 36, height: 36)
                .accessibilityLabel(source.kind == .smb ? "On this \(DeviceStorage.device)" : "Also on the NAS")
        }
    }

    @ViewBuilder
    private func actions(_ book: Book, _ action: Action?, _ status: Status) -> some View {
        let size = book.totalBytes.byteCountString
        if let job = status.jobs[book.id] {
            Button("Stop", systemImage: "stop.circle") { downloads.cancel(job.id) }
        }
        switch action {
        case .download:
            Button("Download (\(size))", systemImage: "arrow.down.circle") { download([book]) }
        case .upload:
            Button("Upload to \(serverName) (\(size))", systemImage: "arrow.up.circle") { upload([book]) }
        case .remove:
            Button("Remove Download (\(size))", systemImage: "trash", role: .destructive) { remove([book], status) }
        case nil:
            EmptyView()
        }
        if canMove, status.jobs[book.id] == nil {
            Button("Move into Earmark (\(size))", systemImage: "arrow.right.circle") { confirmingMove = [book] }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ books: [Book], _ status: Status) -> some ToolbarContent {
        let actionable = Set(books.filter { isSelectable($0, status) }.map(\.id))
        if !selecting {
            ToolbarItem(placement: .primaryAction) { moreMenu }
        }
        if selecting || !actionable.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Done" : "Select") {
                    withAnimation {
                        selecting.toggle()
                        selection.removeAll()
                    }
                }
            }
        }
        if selecting {
            let picked = books.filter { selection.contains($0.id) }
            let toDownload = self.books(picked, for: .download, status)
            let toUpload = self.books(picked, for: .upload, status)
            let toRemove = self.books(picked, for: .remove, status)
            let toMove = movable(picked, status)
            ToolbarItem(placement: .topBarLeading) {
                Button(!actionable.isEmpty && actionable.isSubset(of: selection) ? "Deselect All" : "Select All") {
                    selection = actionable.isSubset(of: selection) ? [] : actionable
                }
                .disabled(actionable.isEmpty)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                // Words with a count and a size, so it's clear what a tap will do: the bottom
                // bar draws an icon-only label as a bare glyph.
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
                } else if canMove {
                    Button { confirmingMove = toMove } label: {
                        Text(toMove.isEmpty ? "Move" : "Move \(toMove.count) (\(Self.bytes(toMove)))")
                    }
                    .disabled(toMove.isEmpty)
                }
            }
        }
    }

    /// What can be done to the whole source at once, each with its count and size.
    private var moreMenu: some View {
        Menu {
            Button("Rescan", systemImage: "arrow.clockwise") { library.rescan(source.id) }
            if source.kind == .smb {
                let pending = downloads.pendingSync(for: source)
                Button(pending.isEmpty ? "Everything Is on This \(DeviceStorage.device)" : "Download \(pending.count) Missing (\(Self.bytes(pending)))",
                       systemImage: "arrow.down.circle") { syncing = source }
                    .disabled(pending.isEmpty)
            }
            if source.kind == .appDocuments || source.kind == .folder, downloads.mirrorServerID != nil {
                let upload = downloads.mirrorable(in: source)
                Button(upload.isEmpty ? "All Backed Up to \(serverName)" : "Upload \(upload.count) to \(serverName) (\(Self.bytes(upload)))",
                       systemImage: "arrow.up.circle") { mirroring = source }
                    .disabled(upload.isEmpty)
            }
            if source.kind == .folder {
                let moves = downloads.movable(in: source)
                Button(moves.isEmpty ? "Nothing Left to Move" : "Move All \(moves.count) into Earmark (\(Self.bytes(moves)))",
                       systemImage: "arrow.right.circle") { movingAll = source }
                    .disabled(moves.isEmpty)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    // MARK: Doing it

    private func download(_ books: [Book]) {
        for book in library.sorted(books, by: .author) { downloads.download(book) }
        Logger.downloads.info("[sources] queued \(books.count) download(s) from \(source.displayName, privacy: .public)")
        finishSelecting()
    }

    private func upload(_ books: [Book]) {
        guard let server = downloads.mirrorServerID else { return }
        for book in library.sorted(books, by: .author) { downloads.mirror(book, to: server) }
        Logger.downloads.info("[sources] queued \(books.count) upload(s) from \(source.displayName, privacy: .public)")
        finishSelecting()
    }

    private func move(_ books: [Book]) {
        for book in library.sorted(books, by: .author) { downloads.move(book) }
        Logger.downloads.info("[sources] queued \(books.count) move(s) into Earmark from \(source.displayName, privacy: .public)")
        finishSelecting()
    }

    private func remove(_ books: [Book], _ status: Status) {
        let result = player.removeDownloads(books.compactMap { status.pairs[$0.syncKey]?.download }, in: library)
        Logger.downloads.info("[sources] removed \(result.count) download(s), \(result.bytes)B, from \(source.displayName, privacy: .public)")
        finishSelecting()
    }

    private func finishSelecting() {
        guard selecting else { return }
        withAnimation {
            selecting = false
            selection.removeAll()
        }
    }
}
