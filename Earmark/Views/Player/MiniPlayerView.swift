import SwiftUI

/// Lives in the tab bar's bottom accessory (Apple Music style). Collapses to one line
/// when the tab bar minimizes on scroll.
struct MiniPlayerView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let onOpen: () -> Void

    var body: some View {
        if let book = player.book {
            HStack(spacing: 12) {
                if placement != .inline {
                    ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 8)
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if player.isRemote {
                            Image(systemName: "externaldrive.connected.to.line.below")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("Remote")
                        }
                        Text(book.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    if placement != .inline {
                        Text(player.currentChapter?.title ?? book.displayAuthor)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if player.isLoading {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                }
                if placement != .inline {
                    Button {
                        player.skipForward()
                    } label: {
                        SkipGlyph(seconds: settings.skipForwardInterval, forward: true)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(book.title)")
        }
    }
}
