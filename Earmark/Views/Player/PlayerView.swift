import SwiftUI

struct PlayerView: View {
    enum Sheet: Identifiable {
        case speed, sleep, chapters
        var id: Self { self }
    }

    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: Sheet?

    var body: some View {
        NavigationStack {
            Group {
                if let book = player.book {
                    content(for: book)
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "chevron.down") { dismiss() }
                }
                if let book = player.book {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            BookContextMenu(book: book)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .toolbarTitleDisplayMode(.inline)
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .speed: SpeedSheet().presentationDetents([.height(360)])
            case .sleep: SleepTimerSheet().presentationDetents([.medium, .large])
            case .chapters: ChapterListSheet().presentationDetents([.medium, .large])
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func content(for book: Book) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 22)
                .frame(maxWidth: 340)
                .padding(.horizontal, 36)
                .shadow(color: .black.opacity(0.28), radius: 24, y: 14)
                .scaleEffect(player.isPlaying ? 1 : 0.92)
                .animation(.spring(duration: 0.45, bounce: 0.25), value: player.isPlaying)
            Spacer(minLength: 24)

            VStack(spacing: 6) {
                Text(book.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(book.displayAuthor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if player.isRemote {
                    RemoteBadge(serverName: player.remoteServerName ?? "NAS")
                }
                Button {
                    sheet = .chapters
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                        Text(player.currentChapter?.title ?? "Chapters")
                            .lineLimit(1)
                    }
                    .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 20)

            ScrubberView()
                .padding(.horizontal, 24)
            Text(bookLine(for: book))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            Spacer(minLength: 18)

            TransportControls(openSpeed: { sheet = .speed }, openSleep: { sheet = .sleep })
                .padding(.horizontal, 12)
            Spacer(minLength: 10)

            HStack(alignment: .center) {
                RoutePickerView()
                    .frame(width: 44, height: 44)
                if let error = player.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background { PlayerBackdrop(artworkID: book.artworkID) }
    }

    private func bookLine(for book: Book) -> String {
        var parts: [String] = []
        if let index = player.currentChapterIndex, book.chapters.count > 1 {
            parts.append("Chapter \(index + 1) of \(book.chapters.count)")
        }
        parts.append("\(player.bookRemaining.shortDurationString) left")
        if abs(player.speed - 1) > 0.01 {
            parts.append("\(player.bookRemaining.adjusted(forSpeed: player.speed).shortDurationString) at \(TransportControls.speedLabel(player.speed))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Softly blurred cover art behind the player.
struct PlayerBackdrop: View {
    let artworkID: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.systemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80)
                    .saturation(1.3)
                    .opacity(0.45)
                    .overlay(Color(.systemBackground).opacity(0.25))
            }
        }
        .ignoresSafeArea()
        .task(id: artworkID) {
            image = await ArtworkStore.shared.loadImage(for: artworkID)
        }
    }
}
