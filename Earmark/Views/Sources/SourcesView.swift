import SwiftUI
import UniformTypeIdentifiers
import os
import ShelfKit

/// Where the books come from — Earmark's own folder, folders the user picked, NAS shares — laid
/// out as Mango's Sources are. Adding one never copies anything: it keeps a security-scoped
/// bookmark to a folder, or a share's login in the Keychain.
struct SourcesView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var showImporter = false
    @State private var showNASSetup = false
    @State private var sourceToRemove: LibrarySource?
    @State private var syncSource: LibrarySource?
    @State private var moveSource: LibrarySource?
    @State private var confirmingUploadAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.sources) { source in
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
                            if source.isRemote {
                                Button("Sync", systemImage: "arrow.down.circle") { syncSource = source }
                                    .tint(.green)
                            } else if source.kind == .folder {
                                Button("Move In", systemImage: "arrow.right.doc.on.clipboard") { moveSource = source }
                                    .tint(.green)
                            }
                        }
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Earmark plays your files where they are. It never copies, moves, renames or deletes them unless you ask — only covers and a small library file are written.")
                }

                Section {
                    Button("Add Folder…", systemImage: "folder.badge.plus") { showImporter = true }
                    Button("Add NAS Share…", systemImage: "externaldrive.badge.plus") { showNASSetup = true }
                }

                if !downloads.jobs.isEmpty {
                    Section {
                        ForEach(downloads.jobs) { job in
                            TransferRow(job: job)
                        }
                    } header: {
                        Text("Transfers")
                    } footer: {
                        Text("One at a time. The screen stays awake while transferring. Transfers keep going while Earmark is open or a book is playing; if iOS suspends the app they pause and resume from where they stopped when you return, and iOS may also grant time while the phone is idle.")
                    }
                    Section {
                        if downloads.isSyncing {
                            Button("Stop All", role: .destructive) { downloads.cancelAll() }
                        }
                        if downloads.jobs.contains(where: { !$0.isActive }) {
                            Button("Clear Finished") { downloads.clearFinished() }
                        }
                    }
                }

                syncSection

                Section("Tools") {
                    NavigationLink {
                        DuplicatesView()
                    } label: {
                        Label("Find Duplicates", systemImage: "doc.on.doc")
                    }
                }

                Section("Library") {
                    let books = library.visibleBooks
                    LabeledContent("Books", value: "\(books.count)")
                    LabeledContent("Authors", value: "\(Set(books.map(\.displayAuthor)).count)")
                    LabeledContent("Total size", value: books.reduce(Int64(0)) { $0 + $1.totalBytes }.byteCountString)
                    LabeledContent("Total length", value: books.reduce(0) { $0 + $1.totalDuration }.shortDurationString)
                }

                Section("Tips") {
                    TipRowView(systemImage: "iphone", title: "Keep books on this phone",
                               detail: "In the Files app, move audiobooks into \(DeviceStorage.earmarkFolder). They stay put and show up here automatically.")
                    TipRowView(systemImage: "externaldrive.connected.to.line.below", title: "Play from a NAS",
                               detail: "Add NAS Share… streams books straight from an SMB share on your network, and downloads any you want to keep.")
                    TipRowView(systemImage: "folder", title: "Folder layout that just works",
                               detail: "Author / Series / Book / chapters. Earmark also reads tags and merges Disc 1, Disc 2 folders into one book.")
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rescan Everything", systemImage: "arrow.clockwise") { library.rescanAll(reason: "manual") }
                        .disabled(library.isScanning)
                }
            }
            .navigationDestination(for: LibrarySource.self) { source in
                SourceBrowserView(source: source)
            }
            .alert("Sources", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
                Button("OK") {}
            } message: {
                Text(library.notice ?? "")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Logger.ui.info("[ui] picked \(urls.count) folder(s) from Sources")
                    library.addFolders(urls)
                }
            }
            .sheet(isPresented: $showNASSetup) {
                NASSetupView()
            }
            .syncConfirmation(source: $syncSource)
            .moveConfirmation(source: $moveSource)
            .confirmationDialog(uploadAllTitle, isPresented: $confirmingUploadAll, titleVisibility: .visible) {
                Button("Upload All") { uploadAll() }
                    .disabled(uploadable.isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each book is uploaded to \(serverName), one at a time. Your copies stay on this \(DeviceStorage.device); books already on the NAS are skipped. Keep Earmark open while it runs.")
            }
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
                    ? "Disconnects from this NAS and forgets its login. Books you downloaded stay on this \(DeviceStorage.device)."
                    : "The files stay on disk. Only Earmark's link to this folder is removed; listening progress is kept in case you add it back.")
            }
        }
    }

    // MARK: Sync

    private var serverName: String {
        downloads.mirrorServerID.flatMap { library.server(id: $0)?.name } ?? "NAS"
    }

    /// Books on this iPhone — in Earmark's folder or one the user picked — not on the NAS yet.
    private var uploadable: [(source: LibrarySource, books: [Book])] {
        library.sources.filter { !$0.isRemote }.map { ($0, downloads.mirrorable(in: $0)) }.filter { !$0.books.isEmpty }
    }

    private var uploadAllTitle: String {
        let books = uploadable.flatMap(\.books)
        return "Upload \(books.count) book\(books.count == 1 ? "" : "s") (\(books.reduce(Int64(0)) { $0 + $1.totalBytes }.byteCountString)) to \(serverName)?"
    }

    private func uploadAll() {
        let count = uploadable.reduce(0) { $0 + downloads.mirrorAll(from: $1.source) }
        Logger.downloads.info("[sources] upload everything: \(count) book(s) to \(self.serverName, privacy: .public)")
    }

    /// Everything at once, as Mango's Sources has it: a NAS's books down to this iPhone, or this
    /// iPhone's books up to the NAS.
    @ViewBuilder
    private var syncSection: some View {
        let remotes = library.sources.filter(\.isRemote)
        if !remotes.isEmpty || downloads.mirrorServerID != nil {
            Section {
                ForEach(remotes) { source in
                    Button("Download Everything from \(source.displayName)", systemImage: "arrow.down.circle") { syncSource = source }
                }
                if downloads.mirrorServerID != nil {
                    Button("Upload Everything to \(serverName)", systemImage: "arrow.up.circle") { confirmingUploadAll = true }
                        .disabled(uploadable.isEmpty)
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Books on a NAS stream while you're on its network. Download any of them to keep a copy on this \(DeviceStorage.device); files you already have are skipped.")
            }
        }
    }
}

/// A source in the list, as Mango draws its sources (`SourceRowView`), with Earmark's words.
struct SourceRow: View {
    @Environment(LibraryModel.self) private var library
    let source: LibrarySource

    var body: some View {
        SourceRowView(systemImage: source.systemImage,
                      name: source.kind == .appDocuments ? DeviceStorage.earmarkFolder : source.displayName,
                      location: source.serverID.flatMap { library.server(id: $0)?.displayLocation },
                      status: statusLine, isError: hasError, isScanning: isScanning)
    }

    private var status: LibraryModel.ScanStatus { library.scanStatus[source.id] ?? .idle }

    private var isScanning: Bool {
        if case .scanning = status { return true }
        return false
    }

    private var hasError: Bool {
        if case .failed = status { return true }
        if let serverID = source.serverID, case .offline = library.nasStatus[serverID] { return true }
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
            return SourceRowView.scanSummary(items: source.lastScanBookCount ?? 0, noun: "book",
                                             files: source.lastScanFileCount ?? 0, at: source.lastScanAt)
        }
    }
}

/// A transfer in the list (`TransferRowView`, as Mango's are).
struct TransferRow: View {
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadManager.Job

    var body: some View {
        TransferRowView(kind: job.kind == .download ? .download : job.kind == .mirror ? .upload : .move,
                        title: job.title, phase: phase, fraction: job.fraction,
                        doneBytes: job.doneBytes, totalBytes: job.totalBytes, error: job.error,
                        cancel: { downloads.cancel(job.id) }, retry: { downloads.retry(job.id) })
    }

    private var phase: TransferRowView.Phase {
        switch job.state {
        case .queued: .queued
        case .running: .running
        case .done: .done
        case .failed: .failed
        case .cancelled: .cancelled
        }
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

    @ViewBuilder
    private var hiddenList: some View {
        if library.hiddenBooks.isEmpty {
            ContentUnavailableView("Nothing Hidden", systemImage: "eye",
                                   description: Text("Hide a book from its menu: touch and hold it anywhere in the library."))
                .navigationTitle("Hidden Books")
        } else {
            hiddenBooksList
        }
    }

    private var hiddenBooksList: some View {
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

extension View {
    /// Confirmation dialog shared by the swipe action, the Sync section and a source's menu.
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
            "Download \(pending.count) book\(pending.count == 1 ? "" : "s") (\(bytes.byteCountString)) to this \(DeviceStorage.device)?",
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
            Text("Copies go to \(DeviceStorage.earmarkFolder) with the same folder layout. Keep Earmark open, or keep listening, while it downloads; files you already have are skipped.")
        }
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
            Text("Each book is copied into \(DeviceStorage.earmarkFolder) and verified before its original is deleted from \(source?.displayName ?? "the folder"). Your place, bookmarks and corrections go with it; a different file already in Earmark's folder is never replaced. Keep Earmark open while it runs.")
        }
    }
}
