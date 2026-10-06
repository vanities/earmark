import SwiftUI

/// Mark a library book finished with a chosen date (backdating for history) and an optional rating.
struct MarkFinishedSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    let book: Book

    @State private var finishedAt = Date.now
    @State private var rating: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(book.title).font(.headline)
                    BookCreditsView(book: book, authorFont: .subheadline)
                }
                Section("Finished On") {
                    DatePicker("Date", selection: $finishedAt, in: ...Date.now, displayedComponents: .date)
                }
                Section("Rating") {
                    StarRatingPicker(rating: $rating)
                }
            }
            .navigationTitle("Mark Finished")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        library.markFinished(book.id, on: finishedAt)
                        if let rating { library.setRating(book.id, rating) }
                        if player.book?.id == book.id { player.pause() }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                let existing = library.progress(for: book.id)
                finishedAt = existing.finishedAt ?? existing.lastPlayedAt ?? .now
                rating = existing.rating
            }
        }
    }
}
