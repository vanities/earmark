import SwiftUI

/// Search online catalogs for cover art and apply the pick to a book.
struct CoverPickerView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    let book: Book

    @State private var query: String
    @State private var results: [CoverCandidate] = []
    @State private var isSearching = false
    @State private var applying: String?
    @State private var errorMessage: String?

    init(book: Book) {
        self.book = book
        _query = State(initialValue: [book.title, book.author].compactMap { $0 }.joined(separator: " "))
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearching && results.isEmpty {
                    ProgressView("Searching…")
                } else if results.isEmpty {
                    ContentUnavailableView("No Covers Found", systemImage: "photo", description: Text("Try fewer words, or just the title."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 14)], spacing: 18) {
                            ForEach(results) { candidate in
                                Button {
                                    apply(candidate)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        AsyncImage(url: candidate.thumbnailURL) { phase in
                                            if let image = phase.image {
                                                image.resizable().scaledToFill()
                                            } else {
                                                Color(.tertiarySystemFill)
                                            }
                                        }
                                        .aspectRatio(1, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay {
                                            if applying == candidate.id { ProgressView().tint(.white) }
                                        }
                                        Text(candidate.title).font(.caption.weight(.semibold)).lineLimit(2)
                                        Text(candidate.author ?? candidate.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        Text(candidate.source).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(applying != nil)
                            }
                        }
                        .padding()
                    }
                }
            }
            .searchable(text: $query, prompt: "Title and author")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("Find Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Couldn't Save Cover", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await search() }
        }
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        let parts = query.split(separator: " ", maxSplits: 1).map(String.init)
        results = await CoverSearch.search(title: query, author: nil)
        if results.isEmpty, parts.count > 1 {
            results = await CoverSearch.search(title: parts[0], author: nil)
        }
    }

    private func apply(_ candidate: CoverCandidate) {
        applying = candidate.id
        Task {
            defer { applying = nil }
            do {
                let data = try await CoverSearch.download(candidate.fullURL)
                if library.setCustomArtwork(data, for: book) {
                    dismiss()
                } else {
                    errorMessage = "That image couldn't be read."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
