import SwiftUI

/// Look Up: search a real catalog for the book and pick what it is. Nothing is saved until the
/// details form it fills is.
struct BookLookupView: View {
    let initialQuery: String
    let onPick: (BookMatch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var matches: [BookMatch] = []
    @State private var searching = false
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Title and author", text: $query)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                        if searching { ProgressView() }
                    }
                } footer: {
                    Text("Sends these words to Apple Books and Open Library — nothing else.")
                }
                if searched, matches.isEmpty, !searching {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(matches) { match in
                    Button {
                        onPick(match)
                        dismiss()
                    } label: {
                        row(match)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Look Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                query = initialQuery
                await search()
            }
        }
    }

    private func row(_ match: BookMatch) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: match.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 40, height: 40)
            .clipShape(.rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(match.title).lineLimit(2)
                Text(detail(match)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// "Brandon Sanderson · The Stormlight Archive #1 · 2010 · Apple Books".
    private func detail(_ match: BookMatch) -> String {
        var parts: [String] = []
        if let author = match.author { parts.append(author) }
        if let series = match.series {
            parts.append(match.seriesIndex.map { "\(series) #\(BookDetailView.format($0))" } ?? series)
        }
        if let year = match.year { parts.append(String(year)) }
        parts.append(match.source)
        return parts.joined(separator: " · ")
    }

    private func search() async {
        searching = true
        matches = await BookLookup.search(query)
        searching = false
        searched = true
    }
}
