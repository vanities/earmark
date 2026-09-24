import SwiftUI
import ShelfKit
import UniformTypeIdentifiers
import os

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppSettings.self) private var settings
    let openPlayer: () -> Void

    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showingLists = false
    @State private var showingOffline = false
    @State private var showingBookmarks = false
    @State private var showingQueue = false
    @State private var importError: String?

    private var filteredBooks: [Book] {
        var books = library.visibleBooks
        if !settings.showFinishedBooks {
            books = books.filter { !library.isFinished($0) }
        }
        books = library.search(searchText, in: books)
        return library.sorted(books, by: settings.librarySort)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .searchable(text: $searchText, prompt: "Books, authors, series")
                .toolbar { toolbar }
                .sheet(isPresented: $showingQueue) { ListeningQueueSheet() }
                .navigationDestination(for: Book.self) { book in
                    BookDetailView(book: book, openPlayer: openPlayer)
                }
                .sheet(isPresented: $showingOffline) { OfflineLibraryView() }
                .sheet(isPresented: $showingBookmarks) { BookmarkSearchView() }
                .navigationDestination(isPresented: $showingLists) { ListsView() }
                .navigationDestination(for: LibraryGroup.self) { group in
                    if group.id.hasPrefix("author:") {
                        AuthorShelfView(group: group, openPlayer: openPlayer)
                    } else {
                        GroupShelfView(group: group, openPlayer: openPlayer)
                    }
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls):
                        Logger.ui.info("[ui] picked \(urls.count) folder(s)")
                        library.addFolders(urls)
                    case .failure(let error):
                        importError = error.localizedDescription
                    }
                }
                .alert("Couldn't Add Folder", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                    Button("OK") {}
                } message: {
                    Text(importError ?? "")
                }
                .alert("Folders", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
                    Button("OK") {}
                } message: {
                    Text(library.notice ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.visibleBooks.isEmpty {
            if library.isScanning {
                ContentUnavailableView {
                    ProgressView().controlSize(.large)
                } description: {
                    Text("Reading your folders…")
                }
            } else {
                // Pull to look again, as the full shelf can: before this, a shelf left empty by
                // books added while Earmark was open stayed empty until a relaunch.
                ScrollView {
                    EmptyLibraryView(addFolder: { showImporter = true })
                        .containerRelativeFrame(.vertical)
                }
                .refreshable { await refresh() }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if searchText.isEmpty, !library.inProgressBooks.isEmpty {
                        ContinueListeningSection(books: library.inProgressBooks, openPlayer: openPlayer)
                    }
                    if settings.libraryGrouping == .all || !searchText.isEmpty {
                        BookGridSection(title: searchText.isEmpty ? "All Books" : "Results", books: filteredBooks, layout: settings.libraryLayout)
                    } else {
                        SectionHeader(settings.libraryGrouping.title, count: library.groups(settings.libraryGrouping, from: filteredBooks).count)
                        GroupListSection(groups: library.groups(settings.libraryGrouping, from: filteredBooks))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .overlay(alignment: .bottom) {
                if library.isScanning {
                    ScanBanner().padding(.bottom, 12)
                }
            }
            .refreshable { await refresh() }
        }
    }

    /// Pull to rescan, as in Mango; the spinner stays until the folders have been read (or half
    /// a minute, for a NAS that's slow to answer).
    private func refresh() async {
        library.rescanAll(reason: "pull to refresh")
        for _ in 0..<150 where library.isScanning {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The same two buttons as Mango's Library: the lists, and one menu for how the shelf looks
    /// and for bringing books in. Group By and Sort By are submenus, so the menu stays short.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Lists", systemImage: "list.bullet.rectangle") { showingLists = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Bookmarks & notes…", systemImage: "bookmark") { showingBookmarks = true }
                Button("Ready for offline…", systemImage: "checkmark.icloud") { showingOffline = true }
                Divider()
                Button("Listening queue…", systemImage: "list.bullet") { showingQueue = true }
                Divider()
                Picker("Group By", systemImage: "rectangle.3.group", selection: Bindable(settings).libraryGrouping) {
                    ForEach(LibraryGrouping.allCases, id: \.self) { grouping in
                        Label(grouping.title, systemImage: grouping.systemImage).tag(grouping)
                    }
                }
                .pickerStyle(.menu)
                Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: Bindable(settings).librarySort) {
                    ForEach(LibrarySort.allCases, id: \.self) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.menu)
                Picker("Layout", selection: Bindable(settings).libraryLayout) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                }
                Toggle("Show Finished", isOn: Bindable(settings).showFinishedBooks)
                Divider()
                Button("Rescan", systemImage: "arrow.clockwise") { library.rescanAll(reason: "library menu") }
                Button("Add Folder…", systemImage: "folder.badge.plus") { showImporter = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

// MARK: - Sections

/// The books under way, as Mango's Continue Reading shows comics: a row of cover tiles with how
/// far along each is. A tap plays (or pauses) right there, as the cards before them did.
struct ContinueListeningSection: View {
    let books: [Book]
    let openPlayer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue Listening")
                .font(.headline)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(books.prefix(12)) { book in
                        ContinueTile(book: book, openPlayer: openPlayer)
                            .frame(width: 110)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

/// Cover, progress and where you are — Mango's `ComicThumbnail`, for a book, with a play/pause
/// badge because a tap here plays it.
struct ContinueTile: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    let book: Book
    let openPlayer: () -> Void

    private var isPlaying: Bool { player.book?.id == book.id && player.isPlaying }

    var body: some View {
        let progress = library.progress(for: book.id)
        Button {
            if isPlaying {
                player.pause()
            } else {
                player.load(book, autoplay: true)
                openPlayer()
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 8)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        ProgressBar(fraction: progress.fraction(of: book), height: 3)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .padding(5)
                    }
                Text(book.title)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(progress.remaining(in: book).shortDurationString) left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { BookContextMenu(book: book) }
        .accessibilityLabel("\(book.title), \(progress.remaining(in: book).shortDurationString) left")
        .accessibilityHint(isPlaying ? "Pauses" : "Plays")
    }
}

struct BookGridSection: View {
    let title: String
    let books: [Book]
    let layout: LibraryLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title, count: books.count)
            if books.isEmpty {
                Text("No matches.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else if layout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16, alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(books) { book in
                        NavigationLink(value: book) {
                            BookCardView(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(books) { book in
                        NavigationLink(value: book) {
                            BookRowView(book: book)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }
}

struct GroupListSection: View {
    let groups: [LibraryGroup]

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(groups) { group in
                NavigationLink(value: group) {
                    HStack(spacing: 14) {
                        CoverStack(books: group.books)
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(group.subtitle ?? "\(group.books.count) books")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }
}

/// Up to three fanned covers for a shelf.
struct CoverStack: View {
    let books: [Book]
    /// The square it fills: 72 in a Library row, the header's cover width on a shelf's page.
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            ForEach(Array(books.prefix(3).enumerated().reversed()), id: \.element.id) { index, book in
                ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: size / 9)
                    .frame(width: size * 7 / 9, height: size * 7 / 9)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .offset(x: CGFloat(index) * size / 9, y: CGFloat(-index) * size / 12)
            }
        }
        .frame(width: size, height: size, alignment: .bottomLeading)
    }
}

struct ScanBanner: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label)
                .font(.footnote.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect()
    }

    private var label: String {
        for status in library.scanStatus.values {
            if case .scanning(let progress) = status {
                switch progress.phase {
                case .enumerating: return "Reading folders…"
                case .metadata: return progress.total > 0 ? "Reading tags \(progress.processed)/\(progress.total)" : "Reading tags…"
                case .artwork: return "Finding covers…"
                }
            }
        }
        return "Scanning…"
    }
}

struct EmptyLibraryView: View {
    let addFolder: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your Shelf Is Empty", systemImage: "books.vertical")
        } description: {
            Text("Add a folder of audiobooks. Earmark plays them right where they are — nothing gets copied.\n\nOr move files into **\(DeviceStorage.earmarkFolder)** in the Files app, or open one with Earmark.")
        } actions: {
            Button("Add a Folder", systemImage: "folder.badge.plus", action: addFolder)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
