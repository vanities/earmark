import SwiftUI

struct DuplicatesView: View {
    @Environment(LibraryModel.self) private var library
    @State private var pendingDelete: [DuplicateFile] = []
    @State private var confirmDelete = false
    @State private var errors: [String] = []

    var body: some View {
        List {
            switch library.duplicateScan {
            case .idle:
                ContentUnavailableView {
                    Label("Find Duplicate Books", systemImage: "doc.on.doc")
                } description: {
                    Text("Compares every file by size and content — not just name — so copies made by other apps or iCloud get caught too. Nothing is deleted without asking.")
                } actions: {
                    Button("Scan for Duplicates") { library.findDuplicates() }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            case .running(let done, let total):
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text("Fingerprinting \(done) of \(total) files…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            case .finished:
                if library.duplicateGroups.isEmpty {
                    ContentUnavailableView("No Duplicates", systemImage: "checkmark.seal", description: Text("Every file in your library is unique."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        let wasted = library.duplicateGroups.reduce(Int64(0)) { $0 + $1.wastedBytes }
                        Label("\(library.duplicateGroups.count) duplicate set\(library.duplicateGroups.count == 1 ? "" : "s") · \(wasted.byteCountString) reclaimable", systemImage: "internaldrive")
                            .font(.subheadline)
                    }
                    ForEach(library.duplicateGroups) { group in
                        Section {
                            switch group.kind {
                            case .wholeBook:
                                ForEach(group.books) { book in
                                    DuplicateBookRow(book: book) {
                                        pendingDelete = book.tracks.map {
                                            DuplicateFile(bookID: book.id, bookTitle: book.title, sourceID: book.sourceID, relativePath: $0.relativePath, size: $0.fileSize)
                                        }
                                        confirmDelete = true
                                    }
                                }
                            case .files:
                                ForEach(group.files) { file in
                                    DuplicateFileRow(file: file) {
                                        pendingDelete = [file]
                                        confirmDelete = true
                                    }
                                }
                            }
                        } header: {
                            switch group.kind {
                            case .wholeBook: Text("\(group.books.first?.title ?? "Book") · \(group.books.count) identical copies")
                            case .files: Text("Same file in \(group.files.count) places")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
        .toolbar {
            if case .finished = library.duplicateScan {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rescan", systemImage: "arrow.clockwise") { library.findDuplicates() }
                }
            }
        }
        .confirmationDialog("Delete \(pendingDelete.count) file\(pendingDelete.count == 1 ? "" : "s") from disk?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                errors = library.deleteFiles(pendingDelete)
                pendingDelete = []
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("The other copy stays. This cannot be undone.")
        }
        .alert("Some files couldn't be deleted", isPresented: Binding(get: { !errors.isEmpty }, set: { if !$0 { errors = [] } })) {
            Button("OK") {}
        } message: {
            Text(errors.joined(separator: "\n"))
        }
    }
}

struct DuplicateBookRow: View {
    @Environment(LibraryModel.self) private var library
    let book: Book
    let delete: () -> Void

    var body: some View {
        let progress = library.progress(for: book.id)
        HStack(spacing: 12) {
            ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(library.sourceName(for: book.sourceID)) › \(book.relativePath)")
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(book.totalBytes.byteCountString) · \(book.tracks.count) file\(book.tracks.count == 1 ? "" : "s")\(progress.hasStarted ? " · has listening progress" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            Button("Hide", systemImage: "eye.slash") { library.setHidden(true, bookID: book.id) }
        }
        .contextMenu {
            Button("Delete This Copy…", systemImage: "trash", role: .destructive, action: delete)
            Button("Hide from Library", systemImage: "eye.slash") { library.setHidden(true, bookID: book.id) }
            Button("Show in Files", systemImage: "folder") { library.revealInFiles(book) }
        }
    }
}

struct DuplicateFileRow: View {
    @Environment(LibraryModel.self) private var library
    let file: DuplicateFile
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(library.sourceName(for: file.sourceID)) › \(file.relativePath)")
                .font(.subheadline)
                .lineLimit(2)
            Text("\(file.bookTitle) · \(file.size.byteCountString)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}
