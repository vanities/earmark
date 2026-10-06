import SwiftUI
import ShelfKit

struct BookmarkSearchView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Result: Identifiable {
        let book: Book
        let mark: Bookmark
        var id: String { "\(book.id)|\(mark.id)" }
        var location: String { mark.offset.clockString }
    }
    private var results: [Result] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return library.visibleBooks.flatMap { book in
            library.bookmarks(for: book).map { Result(book: book, mark: $0) }
        }.filter { result in
            let text = [result.book.title, result.book.series ?? "", result.book.author ?? "", result.book.narrator ?? "", result.mark.note, result.location].joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }.sorted { $0.mark.createdAt > $1.mark.createdAt }
    }
    var body: some View {
        NavigationStack {
            List(results) { result in
                Button {
                    player.load(result.book, autoplay: true, startAt: result.book.position(atAbsoluteOffset: result.mark.offset))
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        BookmarkSearchRow(title: result.book.title, note: result.mark.note, location: result.location)
                        BookCreditsView(book: result.book)
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No bookmarks yet" : "No matching bookmarks", systemImage: "bookmark",
                                           description: Text("Save a spot while reading or listening, then find it here by title or note."))
                }
            }
            .searchable(text: $query, prompt: "Titles, bookmarks, notes")
            .navigationTitle("Bookmarks & notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
