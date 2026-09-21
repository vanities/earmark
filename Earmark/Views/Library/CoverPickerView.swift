import PhotosUI
import SwiftUI
import os

/// Search online catalogs for cover art — or pick an image from Photos or Files — and apply it to a book.
struct CoverPickerView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    let book: Book

    @State private var query: String
    @State private var results: [CoverCandidate] = []
    @State private var isSearching = false
    @State private var applying: String?
    @State private var errorMessage: String?
    @State private var showPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFiles = false

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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Choose from Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                        Button("Choose File…", systemImage: "folder") { showFiles = true }
                    } label: {
                        Label("Use Your Own Image", systemImage: "photo.badge.plus")
                    }
                    .disabled(applying != nil)
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task { await applyPhoto(item) }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
                applyFile(result)
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
                if library.setCustomArtwork(data, origin: .online(candidate.fullURL), for: book) {
                    dismiss()
                } else {
                    errorMessage = "That image couldn't be read."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyPhoto(_ item: PhotosPickerItem) async {
        applying = "photos"
        defer { applying = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "That photo couldn't be loaded."
                return
            }
            Logger.artwork.info("[covers] photo picked bytes=\(data.count)")
            applyOwnImage(data)
        } catch {
            Logger.artwork.error("[covers] photo load failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func applyFile(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                Logger.artwork.info("[covers] file picked \(url.lastPathComponent, privacy: .public) bytes=\(data.count)")
                applyOwnImage(data)
            } catch {
                Logger.artwork.error("[covers] file read failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func applyOwnImage(_ data: Data) {
        if library.setCustomArtwork(data, origin: .device, for: book) {
            dismiss()
        } else {
            errorMessage = "That image couldn't be read."
        }
    }
}
