import SwiftUI
import UniformTypeIdentifiers
import os
import ShelfKit

struct FoldersView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var showImporter = false
    @State private var showNASSetup = false
    @State private var sourceToRemove: LibrarySource?
    @State private var syncSource: LibrarySource?
    @State private var moveSource: LibrarySource?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.sources.filter { !$0.isRemote }) { source in
                        NavigationLink(value: source) {
                            SourceRow(source: source)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if source.isRemovable {
                                Button("Remove", systemImage: "trash", role: .destructive) { sourceToRemove = source }
                            }
                            Button("Rescan", systemImage: "arrow.clockwise") { library.rescan(source.id) }
                                .tint(.blue)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if source.kind == .folder {
                                Button("Move In", systemImage: "arrow.right.doc.on.clipboard") { moveSource = source }
                                    .tint(.green)
                            }
                        }
                    }
                } header: {
                    Text("Library Folders")
                } footer: {
                    Text("Earmark plays your files where they are. Nothing is copied or moved.")
                }

                Section {
                    Button("Add Folder…", systemImage: "folder.badge.plus") { showImporter = true }
                    Button("Rescan Everything", systemImage: "arrow.clockwise") { library.rescanAll(reason: "manual") }
                        .disabled(library.isScanning)
                }

                Section {
                    ForEach(library.sources.filter(\.isRemote)) { source in
                        NavigationLink(value: source) {
                            SourceRow(source: source)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Remove", systemImage: "trash", role: .destructive) { sourceToRemove = source }
                            Button("Rescan", systemImage: "arrow.clockwise") { library.rescan(source.id) }
                                .tint(.blue)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button("Sync", systemImage: "arrow.down.circle") { syncSource = source }
                                .tint(.green)
                        }
                    }
                    Button("Add NAS…", systemImage: "externaldrive.badge.plus") { showNASSetup = true }
                } header: {
                    Text("Network")
                } footer: {
                    Text("Books on a NAS stream while you're on its network and are marked Remote. Download any of them to keep a copy on this iPhone.")
                }

                if !downloads.jobs.isEmpty {
                    Section {
                        ForEach(downloads.jobs) { job in
                            DownloadJobRow(job: job)
                        }
                        if downloads.jobs.contains(where: { !$0.isActive }) {
                            Button("Clear Finished") { downloads.clearFinished() }
                        }
                    } header: {
                        Text("Transfers")
                    } footer: {
                        if downloads.isSyncing {
                            Text("One at a time. The screen stays awake while transferring. Transfers keep going while Earmark is open or a book is playing; if iOS suspends the app they pause and resume from where they stopped when you return, and iOS may also grant time while the phone is idle.")
                        }
                    }
                }

                Section("Tools") {
                    NavigationLink {
                        DuplicatesView()
                    } label: {
                        Label("Find Duplicates", systemImage: "doc.on.doc")
                    }
                    if !library.hiddenBooks.isEmpty {
                        NavigationLink {
                            HiddenBooksView()
                        } label: {
                            Label("Hidden Books (\(library.hiddenBooks.count))", systemImage: "eye.slash")
                        }
                    }
                }

                Section("Tips") {
                    TipRow(icon: "iphone", title: "Keep books on this phone", detail: "In the Files app, move audiobooks into On My iPhone › Earmark. They stay put and show up here automatically.")
                    TipRow(icon: "externaldrive.connected.to.line.below", title: "Play from a NAS", detail: "Files › ⋯ › Connect to Server (smb://your-nas), then add that folder here. Native SMB streaming is on the roadmap.")
                    TipRow(icon: "folder", title: "Folder layout that just works", detail: "Author / Series / Book / chapters. Earmark also reads tags and merges Disc 1, Disc 2 folders into one book.")
                }
            }
            .navigationTitle("Folders")
            .navigationDestination(for: LibrarySource.self) { source in
                SourceDetailView(source: source)
            }
            .alert("Folders", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
                Button("OK") {}
            } message: {
                Text(library.notice ?? "")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Logger.ui.info("[ui] picked \(urls.count) folder(s) from Folders")
                    library.addFolders(urls)
                }
            }
            .sheet(isPresented: $showNASSetup) {
                NASSetupView()
            }
            .syncConfirmation(source: $syncSource)
            .moveConfirmation(source: $moveSource)
            .confirmationDialog(
                "Remove \(sourceToRemove?.displayName ?? "folder")?",
                isPresented: Binding(get: { sourceToRemove != nil }, set: { if !$0 { sourceToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove from Earmark", role: .destructive) {
                    if let source = sourceToRemove { library.removeSource(source.id) }
                    sourceToRemove = nil
                }
            } message: {
                Text(sourceToRemove?.isRemote == true
                    ? "Disconnects from this NAS and forgets its login. Books you downloaded stay on this iPhone."
                    : "The files stay on disk. Only Earmark's link to this folder is removed; listening progress is kept in case you add it back.")
            }
        }
    }
}

struct SourceRow: View {
    @Environment(LibraryModel.self) private var library
    let source: LibrarySource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.kind == .appDocuments ? "On My iPhone › Earmark" : source.displayName)
                    .font(.body.weight(.medium))
                if let server = source.serverID.flatMap({ library.server(id: $0) }) {
                    Text(server.displayLocation)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(hasError ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isScanning {
                ProgressView()
            }
        }
    }

    private var status: LibraryModel.ScanStatus { library.scanStatus[source.id] ?? .idle }

    private var isScanning: Bool {
        if case .scanning = status { return true }
        return false
    }

    private var hasError: Bool {
        if case .failed = status { return true }
        return source.lastError != nil
    }

    private var statusLine: String {
        if let serverID = source.serverID {
            switch library.nasStatus[serverID] {
            case .connecting: return "Connecting…"
            case .offline(let message): return message
            default: break
            }
        }
        switch status {
        case .scanning(let progress):
            switch progress.phase {
            case .enumerating: return "Reading folder…"
            case .metadata: return progress.total > 0 ? "Reading tags \(progress.processed) of \(progress.total)" : "Reading tags…"
            case .artwork: return "Finding covers…"
            }
        case .failed(let message):
            return message
        case .idle:
            if let error = source.lastError { return error }
            guard let scanned = source.lastScanAt else { return "Not scanned yet" }
            let books = source.lastScanBookCount ?? 0
            let files = source.lastScanFileCount ?? 0
            let when = scanned.formatted(.relative(presentation: .named))
            if files == 0 { return "Empty · checked \(when)" }
            return "\(books) book\(books == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s") · scanned \(when)"
        }
    }
}

struct TipRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SourceDetailView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    let source: LibrarySource
    @State private var selecting = false

    var body: some View {
        let books = library.books(inSource: source.id)
        let unsupported = library.unsupportedFiles[source.id] ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let root = library.rootURL(for: source.id) {
                    Text(root.path(percentEncoded: false))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                } else if let server = source.serverID.flatMap({ library.server(id: $0) }) {
                    Label(server.displayLocation, systemImage: "externaldrive.connected.to.line.below")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    SyncFromNASButton(source: source)
                        .padding(.horizontal)
                }
                if source.kind == .folder {
                    MoveIntoEarmarkButton(source: source)
                        .padding(.horizontal)
                }
                if (source.kind == .appDocuments || source.kind == .folder), !library.nasServers.isEmpty {
                    MirrorToNASButton(source: source)
                        .padding(.horizontal)
                }
                if !unsupported.isEmpty {
                    DisclosureGroup {
                        ForEach(unsupported, id: \.self) { path in
                            Text(path).font(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        Label("\(unsupported.count) file\(unsupported.count == 1 ? "" : "s") iOS can't play (.ogg/.wma/.opus)", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal)
                }
                if books.isEmpty {
                    ContentUnavailableView("No Books Here", systemImage: "folder", description: Text(source.kind == .appDocuments ? "Move audiobooks into On My iPhone › Earmark using the Files app." : "No playable audio files were found in this folder."))
                } else {
                    BookGridSection(title: "Books", books: library.sorted(books, by: .title), layout: settings.libraryLayout)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(source.kind == .appDocuments ? "On My iPhone" : source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rescan", systemImage: "arrow.clockwise") { library.rescan(source.id) }
            }
            // Several at once: download them, or remove downloads and play from the NAS again.
            // (Counted from every book here: once all of a NAS is downloaded, `books` is empty.)
            if library.books.contains(where: { $0.sourceID == source.id }),
               source.kind == .smb || downloads.mirrorServerID != nil || !library.downloadPairs().isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { selecting = true }
                }
            }
        }
        .sheet(isPresented: $selecting) { SelectBooksView(source: source) }
        .navigationDestination(for: Book.self) { book in
            BookDetailView(book: book, openPlayer: {})
        }
    }
}

struct MirrorToNASButton: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryModel.self) private var library
    let source: LibrarySource
    @State private var confirming: LibrarySource?

    var body: some View {
        let books = downloads.mirrorable(in: source)
        let bytes = books.reduce(Int64(0)) { $0 + $1.totalBytes }
        let serverName = downloads.mirrorServerID.flatMap { library.server(id: $0)?.name } ?? "NAS"
        VStack(alignment: .leading, spacing: 6) {
            Button {
                confirming = source
            } label: {
                Label(books.isEmpty ? "All Backed Up to \(serverName)" : "Mirror to \(serverName)", systemImage: "arrow.up.doc.on.clipboard")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(books.isEmpty)
            if !books.isEmpty {
                Text("\(books.count) book\(books.count == 1 ? "" : "s") · \(bytes.byteCountString). Uploads to \(serverName), one at a time, keeping your files here. Books already on the NAS are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .mirrorConfirmation(source: $confirming)
    }
}

extension View {
    func mirrorConfirmation(source: Binding<LibrarySource?>) -> some View {
        modifier(MirrorConfirmationModifier(source: source))
    }
}

private struct MirrorConfirmationModifier: ViewModifier {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryModel.self) private var library
    @Binding var source: LibrarySource?

    func body(content: Content) -> some View {
        let books = source.map { downloads.mirrorable(in: $0) } ?? []
        let bytes = books.reduce(Int64(0)) { $0 + $1.totalBytes }
        let serverName = downloads.mirrorServerID.flatMap { library.server(id: $0)?.name } ?? "NAS"
        content.confirmationDialog(
            "Mirror \(books.count) book\(books.count == 1 ? "" : "s") (\(bytes.byteCountString)) to \(serverName)?",
            isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }),
            titleVisibility: .visible
        ) {
            Button(books.isEmpty ? "Nothing to Mirror" : "Mirror All") {
                if let source { _ = downloads.mirrorAll(from: source) }
                source = nil
            }
            .disabled(books.isEmpty)
            Button("Cancel", role: .cancel) { source = nil }
        } message: {
            Text("Each book is uploaded to \(serverName), one at a time. Your local copies stay where they are; books already on the NAS are skipped. Keep Earmark open while it runs.")
        }
    }
}

/// Everything hidden, and the way back. Behind Face ID when the lock is on — otherwise the list
/// of what's hidden would give it away.
struct HiddenBooksView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var revealed = false

    var body: some View {
        if settings.lockMode != .off && !revealed {
            List {
                Section {
                    Button("Show Hidden Books") {
                        Task { revealed = await AppLock.authenticate(reason: "Show hidden books") }
                    }
                } footer: {
                    Text("Hidden books stay behind Face ID while the lock is on.")
                }
            }
            .navigationTitle("Hidden Books")
        } else {
            hiddenList
        }
    }

    private var hiddenList: some View {
        List(library.hiddenBooks) { book in
            HStack {
                ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading) {
                    Text(book.title).lineLimit(1)
                    Text(book.displayAuthor).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Unhide") { library.setHidden(false, bookID: book.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .navigationTitle("Hidden Books")
    }
}


struct DownloadJobRow: View {
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadManager.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                switch job.state {
                case .queued: Text("Queued").font(.caption).foregroundStyle(.secondary)
                case .running: Text("\(job.kind == .move ? "Moving" : job.kind == .mirror ? "Uploading" : "Downloading") \(Int(job.fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                }
                if job.isActive {
                    Button("Cancel", systemImage: "xmark.circle") { downloads.cancel(job.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            if job.isActive {
                ProgressView(value: job.fraction)
                Text("\(job.doneBytes.byteCountString) of \(job.totalBytes.byteCountString)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else if let error = job.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}


/// "Sync from NAS": one tap to pull every book that isn't on this phone yet.
struct SyncFromNASButton: View {
    @Environment(DownloadManager.self) private var downloads
    let source: LibrarySource
    @State private var confirming: LibrarySource?

    var body: some View {
        let pending = downloads.pendingSync(for: source)
        let bytes = pending.reduce(Int64(0)) { $0 + $1.totalBytes }
        VStack(alignment: .leading, spacing: 6) {
            Button {
                confirming = source
            } label: {
                Label(pending.isEmpty ? "Everything Is on This iPhone" : "Sync from NAS", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(pending.isEmpty)
            if !pending.isEmpty {
                Text("\(pending.count) book\(pending.count == 1 ? "" : "s") · \(bytes.byteCountString) not on this phone yet. Files you already have are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if downloads.isSyncing {
                Text("Downloading… see Folders › Downloads for progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .syncConfirmation(source: $confirming)
    }
}

extension View {
    /// Confirmation dialog shared by the swipe action and the detail button.
    func syncConfirmation(source: Binding<LibrarySource?>) -> some View {
        modifier(SyncConfirmationModifier(source: source))
    }
}

private struct SyncConfirmationModifier: ViewModifier {
    @Environment(DownloadManager.self) private var downloads
    @Binding var source: LibrarySource?

    func body(content: Content) -> some View {
        let pending = source.map { downloads.pendingSync(for: $0) } ?? []
        let bytes = pending.reduce(Int64(0)) { $0 + $1.totalBytes }
        content.confirmationDialog(
            "Download \(pending.count) book\(pending.count == 1 ? "" : "s") (\(bytes.byteCountString)) to this iPhone?",
            isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }),
            titleVisibility: .visible
        ) {
            Button(pending.isEmpty ? "Nothing to Download" : "Download All") {
                if let source { _ = downloads.syncAll(from: source) }
                source = nil
            }
            .disabled(pending.isEmpty)
            Button("Cancel", role: .cancel) { source = nil }
        } message: {
            Text("Copies go to On My iPhone › Earmark with the same folder layout. Keep Earmark open, or keep listening, while it downloads; files you already have are skipped.")
        }
    }
}


/// "Move All into Earmark": consolidate a picked folder (BookPlayer, Downloads…) into On My iPhone › Earmark.
struct MoveIntoEarmarkButton: View {
    @Environment(DownloadManager.self) private var downloads
    let source: LibrarySource
    @State private var confirming: LibrarySource?

    var body: some View {
        let books = downloads.movable(in: source)
        let bytes = books.reduce(Int64(0)) { $0 + $1.totalBytes }
        VStack(alignment: .leading, spacing: 6) {
            Button {
                confirming = source
            } label: {
                Label(books.isEmpty ? "Nothing Left to Move" : "Move All into Earmark", systemImage: "arrow.right.doc.on.clipboard")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(books.isEmpty)
            if !books.isEmpty {
                Text("\(books.count) book\(books.count == 1 ? "" : "s") · \(bytes.byteCountString). Copies into On My iPhone › Earmark, then removes the originals from this folder. Books already in Earmark are skipped and their copies here removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .moveConfirmation(source: $confirming)
    }
}

extension View {
    func moveConfirmation(source: Binding<LibrarySource?>) -> some View {
        modifier(MoveConfirmationModifier(source: source))
    }
}

private struct MoveConfirmationModifier: ViewModifier {
    @Environment(DownloadManager.self) private var downloads
    @Binding var source: LibrarySource?

    func body(content: Content) -> some View {
        let books = source.map { downloads.movable(in: $0) } ?? []
        let bytes = books.reduce(Int64(0)) { $0 + $1.totalBytes }
        content.confirmationDialog(
            "Move \(books.count) book\(books.count == 1 ? "" : "s") (\(bytes.byteCountString)) into Earmark?",
            isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }),
            titleVisibility: .visible
        ) {
            Button(books.isEmpty ? "Nothing to Move" : "Move All") {
                if let source { _ = downloads.moveAll(from: source) }
                source = nil
            }
            .disabled(books.isEmpty)
            Button("Cancel", role: .cancel) { source = nil }
        } message: {
            Text("Each book is copied into On My iPhone › Earmark and verified before its original is deleted from \(source?.displayName ?? "the folder"). Listening progress carries over. Keep Earmark open while it runs.")
        }
    }
}
