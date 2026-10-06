import SwiftUI

struct BookCreditsView: View {
    let book: Book
    var authorFont: Font = .caption
    var narratorFont: Font = .caption

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.displayAuthor).font(authorFont)
            if let narrator = book.narratorCredit {
                Text(narrator).font(narratorFont)
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
