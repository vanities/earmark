import SwiftUI

struct GroupingEditorView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var transfers
    @State private var sourceID: UUID?
    @State private var draft: [Book] = []
    @State private var baseline: [Book] = []
    @State private var selected: Set<String> = []
    @State private var message: String?
    private var busy: Bool { library.isScanning || transfers.jobs.contains { $0.isActive } }
    var body: some View {
        List {
            Section {
                Text("Arrange tracks without changing files. Select books to combine, or open a book to reorder its tracks and split it. Review the preview before applying.").font(.footnote)
                Picker("Source", selection: $sourceID) {
                    Text("Choose a source").tag(Optional<UUID>.none)
                    ForEach(library.sources.filter { $0.kind != .file }) { Text($0.displayName).tag(Optional($0.id)) }
                }.onChange(of: sourceID) { reload() }
                Button("Combine selected books (\(selected.count))") { combine() }.disabled(selected.count < 2)
                Button("Apply preview") { apply() }.disabled(sourceID == nil || draft == baseline || busy)
                if let rule = library.manualGroupings.first(where: { $0.sourceID == sourceID }) {
                    Button("Undo last arrangement") {
                        player.unload()
                        var undo = rule
                        undo.groups = rule.previous ?? rule.original
                        undo.previous = nil
                        library.applyGrouping(undo, undo: undo.groups == rule.original)
                        reload()
                    }.disabled(busy)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            Section("Preview") {
                ForEach(draft) { book in
                    HStack {
                        Button {
                            if selected.contains(book.id) { selected.remove(book.id) } else { selected.insert(book.id) }
                        } label: { Image(systemName: selected.contains(book.id) ? "checkmark.circle.fill" : "circle").frame(width: 44, height: 44) }
                        .buttonStyle(.borderless)
                        NavigationLink {
                            TrackArrangementView(book: book) { replacements in
                                if let index = draft.firstIndex(where: { $0.id == book.id }) { draft.replaceSubrange(index...index, with: replacements) }
                                selected.remove(book.id)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(book.title)
                                BookCreditsView(book: book)
                                Text("\(book.tracks.count) \(book.tracks.count == 1 ? "track" : "tracks")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.navigationTitle("Arrange books and tracks")
    }
    private func reload() {
        baseline = library.books.filter { $0.sourceID == sourceID }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        draft = baseline; selected = []; message = nil
    }
    private func combine() {
        let books = draft.filter { selected.contains($0.id) }
        guard var template = books.first else { return }
        var tracks: [Track] = [], chapters: [Chapter] = []
        for book in books {
            chapters += book.chapters.map { var chapter = $0; chapter.trackIndex += tracks.count; return chapter }
            tracks += book.tracks
        }
        template.tracks = tracks; template.chapters = chapters
        let merged = ManualGrouping.makeBook(template: template, tracks: tracks, title: template.title)
        let index = draft.firstIndex { selected.contains($0.id) } ?? 0
        draft.removeAll { selected.contains($0.id) }
        draft.insert(merged, at: min(index, draft.count)); selected = []
    }
    private func apply() {
        guard let sourceID else { return }
        let current = library.books.filter { $0.sourceID == sourceID }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard current == baseline else { message = "The library changed. Choose the source again to refresh the preview."; return }
        let beforePaths = baseline.flatMap(\.tracks).map(\.relativePath).sorted()
        guard draft.flatMap(\.tracks).map(\.relativePath).sorted() == beforePaths, Set(beforePaths).count == beforePaths.count else {
            message = "Each track must appear exactly once."; return
        }
        let previous = library.manualGroupings.first { $0.sourceID == sourceID }
        let twins = Set(library.books.filter { book in baseline.contains { $0.syncKey == book.syncKey && $0.totalBytes == book.totalBytes } }.map(\.sourceID))
        let copies = twins.union(library.sources.filter { $0.kind == .appDocuments }.map(\.id))
        guard !library.manualGroupings.contains(where: { $0.sourceID != sourceID && !Set($0.groups.flatMap(\.tracks).map(\.relativePath)).isDisjoint(with: beforePaths) }) else {
            message = "Undo the existing arrangement for this book's other source first."; return
        }
        let rule = ManualGrouping(sourceID: sourceID, copySourceIDs: copies,
                                  original: previous?.original ?? baseline, groups: draft, previous: baseline)
        player.unload()
        library.applyGrouping(rule)
        reload(); message = "Arrangement saved. Your place and bookmarks follow their tracks."
    }
}

private struct TrackArrangementView: View {
    let book: Book
    let save: ([Book]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var tracks: [Track] = []
    @State private var splitBefore: String?
    var body: some View {
        List {
            Section {
                TextField("Book title", text: $title)
                Text("Drag tracks into order. Choose a track below to split immediately before it.").font(.footnote)
                Button("Keep as one book") { splitBefore = nil }
            }
            ForEach(tracks) { track in
                Button {
                    splitBefore = splitBefore == track.id ? nil : track.id
                } label: {
                    VStack(alignment: .leading) {
                        if splitBefore == track.id { Label("Start a second book here", systemImage: "scissors").font(.caption).foregroundStyle(.tint) }
                        Text(track.title ?? track.fileName).foregroundStyle(.primary)
                    }.frame(minHeight: 44)
                }
            }.onMove { tracks.move(fromOffsets: $0, toOffset: $1) }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tracks")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Preview") {
                    if let splitBefore, let index = tracks.firstIndex(where: { $0.id == splitBefore }), index > 0 {
                        save([ManualGrouping.makeBook(template: book, tracks: Array(tracks[..<index]), title: title + " — Part 1"),
                              ManualGrouping.makeBook(template: book, tracks: Array(tracks[index...]), title: title + " — Part 2")])
                    } else { save([ManualGrouping.makeBook(template: book, tracks: tracks, title: title)]) }
                    dismiss()
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tracks.isEmpty || splitBefore == tracks.first?.id)
            }
        }
        .onAppear { if tracks.isEmpty { title = book.title; tracks = book.tracks } }
    }
}
