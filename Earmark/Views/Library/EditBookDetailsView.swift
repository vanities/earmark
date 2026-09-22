import SwiftUI

/// Corrects a book's detected metadata. Only fields the user actually changes are stored, so a
/// later rescan still improves everything they left alone. "Reset to Detected" drops the correction.
struct EditBookDetailsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    let book: Book

    @State private var title = ""
    @State private var author = ""
    @State private var series = ""
    @State private var seriesIndex = ""
    @State private var narrator = ""
    @State private var year = ""
    @State private var thinking = false
    @State private var lookingUp = false

    /// Live copy so the form reflects any correction already in place.
    private var current: Book { library.book(id: book.id) ?? book }
    private var hasOverride: Bool { library.metadataOverride(for: book) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Look Up Book…", systemImage: "magnifyingglass") { lookingUp = true }
                } footer: {
                    Text("Finds the book in Apple Books and Open Library; pick the right one to fill these in. Review before saving.")
                }
                if MetadataAI.isAvailable {
                    Section {
                        Button { Task { await suggestWithAI() } } label: {
                            HStack {
                                Label("Suggest with AI", systemImage: "sparkles")
                                Spacer()
                                if thinking { ProgressView() }
                            }
                        }
                        .disabled(thinking)
                    } footer: {
                        Text("Reads the file name and tags with Apple's on-device model to propose a cleaner title, author, series, and narrator. Private and offline — review before saving.")
                    }
                }
                Section("Book") {
                    labeled("Title", text: $title, prompt: current.title)
                    labeled("Author", text: $author, prompt: "Unknown Author")
                }
                Section("Series") {
                    labeled("Series", text: $series, prompt: "None")
                    labeled("Book number", text: $seriesIndex, prompt: "e.g. 2", keyboard: .decimalPad)
                }
                Section("More") {
                    labeled("Narrator", text: $narrator, prompt: "Unknown")
                    labeled("Year", text: $year, prompt: "e.g. 2011", keyboard: .numberPad)
                }
                if hasOverride {
                    Section {
                        Button("Reset to Detected", systemImage: "arrow.uturn.backward", role: .destructive) {
                            library.resetMetadataOverride(for: book)
                            dismiss()
                        }
                    } footer: {
                        Text("Clears your corrections and re-reads the tags and folder names.")
                    }
                }
            }
            .navigationTitle("Edit Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.semibold) }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $lookingUp) {
                BookLookupView(initialQuery: [title, author].filter { !$0.isEmpty }.joined(separator: " "), onPick: apply)
            }
        }
    }

    /// A catalog's match into the form — only what it knows, so nothing typed here is blanked.
    private func apply(_ match: BookMatch) {
        withAnimation(.snappy) {
            title = match.title
            if let a = match.author {
                let split = BookLookup.splitArtist(a, knownAuthor: author)
                author = split.author
                if let n = split.narrator { narrator = n }
            }
            if let se = match.series { series = se }
            if let i = match.seriesIndex { seriesIndex = BookDetailView.format(i) }
            if let y = match.year { year = String(y) }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @ViewBuilder
    private func labeled(_ label: String, text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            TextField(prompt, text: text)
                .keyboardType(keyboard)
                .autocorrectionDisabled(keyboard == .default ? false : true)
        }
    }

    private func load() {
        let b = current
        title = b.title
        author = b.author ?? ""
        series = b.series ?? ""
        seriesIndex = b.seriesIndex.map { BookDetailView.format($0) } ?? ""
        narrator = b.narrator ?? ""
        year = b.year.map(String.init) ?? ""
    }

    private func suggestWithAI() async {
        thinking = true
        defer { thinking = false }
        guard let s = await MetadataAI.suggest(for: current) else { return }
        withAnimation(.snappy) {
            if let t = s.title { title = t }
            if let a = s.author { author = a }
            if let se = s.series { series = se }
            if let i = s.seriesIndex { seriesIndex = BookDetailView.format(i) }
            if let n = s.narrator { narrator = n }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Builds an override of only the fields that differ from what's shown now.
    private func save() {
        let b = current
        var diff = BookMetadataOverride()
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t != b.title { diff.title = t }
        let a = author.trimmingCharacters(in: .whitespaces)
        if a != (b.author ?? "") { diff.author = a }
        let s = series.trimmingCharacters(in: .whitespaces)
        if s != (b.series ?? "") { diff.series = s }
        let idx = Double(seriesIndex.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        if idx != b.seriesIndex, idx != nil { diff.seriesIndex = idx }
        let n = narrator.trimmingCharacters(in: .whitespaces)
        if n != (b.narrator ?? "") { diff.narrator = n }
        let y = Int(year.trimmingCharacters(in: .whitespaces))
        if y != b.year, y != nil { diff.year = y }

        library.setMetadataOverride(diff, for: book)
        dismiss()
    }
}
