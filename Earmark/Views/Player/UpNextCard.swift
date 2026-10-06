import SwiftUI

/// Offered when a book finishes and the next in its series is available. Not auto-played — the
/// listener chooses.
struct UpNextCard: View {
    let book: Book
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 8)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(seriesLine).font(.caption2.weight(.semibold)).foregroundStyle(.tint).textCase(.uppercase)
                Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                BookCreditsView(book: book)
            }
            Spacer(minLength: 4)
            Button(action: onPlay) {
                Image(systemName: "play.fill").font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.tint.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }

    private var seriesLine: String {
        if let series = book.series {
            if let idx = book.seriesIndex { return "Up Next · \(series) \(BookDetailView.format(idx))" }
            return "Up Next · \(series)"
        }
        return "Up Next"
    }
}
