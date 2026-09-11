import SwiftUI

struct BookCardView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    let book: Book

    var body: some View {
        let progress = library.progress(for: book.id)
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(artworkID: book.artworkID, title: book.title)
                .overlay(alignment: .bottom) {
                    if progress.hasStarted, !progress.isFinished {
                        CoverProgressBar(fraction: progress.fraction(of: book))
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if progress.isFinished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .green)
                            .padding(8)
                            .accessibilityHidden(true)
                    } else if player.book?.id == book.id, player.isPlaying {
                        Image(systemName: "speaker.wave.2.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if library.isRemote(book) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.caption.weight(.bold))
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .foregroundStyle(.white)
                            .padding(8)
                            .accessibilityLabel("Remote")
                    }
                }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(book.displayAuthor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(Self.statusLine(for: book, progress: progress))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: book, progress: progress, remote: library.isRemote(book)))
        .accessibilityAddTraits(.isButton)
        .contextMenu { BookContextMenu(book: book) }
    }

    static func accessibilityLabel(for book: Book, progress: PlaybackProgress, remote: Bool) -> String {
        var parts = [book.title, "by \(book.displayAuthor)"]
        if let series = book.series { parts.append(book.seriesIndex.map { "\(series) book \(BookDetailView.format($0))" } ?? series) }
        parts.append(statusLine(for: book, progress: progress))
        if remote { parts.append("on NAS") }
        return parts.joined(separator: ", ")
    }

    static func statusLine(for book: Book, progress: PlaybackProgress) -> String {
        if progress.isFinished { return "Finished" }
        if progress.hasStarted { return "\(progress.remaining(in: book).shortDurationString) left" }
        return book.totalDuration.shortDurationString
    }
}

struct BookRowView: View {
    @Environment(LibraryModel.self) private var library
    let book: Book

    var body: some View {
        let progress = library.progress(for: book.id)
        HStack(spacing: 12) {
            ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 8)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(book.displayAuthor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if progress.hasStarted, !progress.isFinished {
                        ProgressBar(fraction: progress.fraction(of: book))
                            .frame(width: 80)
                    }
                    Text(BookCardView.statusLine(for: book, progress: progress))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu { BookContextMenu(book: book) }
    }
}
