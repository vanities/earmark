import SwiftUI

struct PlayerView: View {
    enum Sheet: Identifiable {
        case speed, sleep, chapters, bookmarks, queue, presets
        var id: Self { self }
    }

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: Sheet?

    var body: some View {
        NavigationStack {
            Group {
                if let book = player.book {
                    PlayerContentView(book: book, sheet: $sheet)
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "chevron.down") { dismiss() }
                }
                if let book = player.book {
                    OverflowToolbar {
                        Button("Listening presets…", systemImage: "slider.horizontal.3") { sheet = .presets }
                        Button("Add Bookmark", systemImage: "bookmark") {
                            _ = library.addBookmark(for: book, offset: player.bookElapsed)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                        Button("Bookmarks\u{2026}", systemImage: "bookmark.fill") { sheet = .bookmarks }
                        Button("Listening queue…", systemImage: "list.bullet") { sheet = .queue }
                        Divider()
                        BookContextMenu(book: book)
                    }
                }
            }
            .toolbarTitleDisplayMode(.inline)
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .presets: NavigationStack { ListeningPresetsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } } }
            case .speed: SpeedSheet().presentationDetents([.height(420)])
            case .sleep: SleepTimerSheet().presentationDetents([.medium, .large])
            case .chapters: ChapterListSheet().presentationDetents([.medium, .large])
            case .queue: ListeningQueueSheet()
            case .bookmarks: BookmarksSheet().presentationDetents([.medium, .large])
            }
        }
        .presentationDragIndicator(.visible)
    }
}

/// The player workspace sizes itself to the space below navigation and safe areas.
struct PlayerContentView: View {
    let book: Book
    @Binding var sheet: PlayerView.Sheet?
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View { content(for: book) }

    private func content(for book: Book) -> some View {
        Group {
#if IPHONE_DUO_LAYOUTS
            if #available(iOS 27.1, *) {
                ArrangementView {
                    artwork(for: book)
                        .frame(maxWidth: 300, maxHeight: 300)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } secondary: {
                    playbackColumn(for: book, showsHeading: true, showsChapters: true)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .arrangementViewStyle(.split)
                .splitArrangementLayoutRatio(0.42)
            } else {
                resizableContent(for: book)
            }
#else
            resizableContent(for: book)
#endif
        }
        .safeAreaInset(edge: .bottom) {
            if let next = player.upNext {
                UpNextCard(book: next,
                           onPlay: { withAnimation(.snappy) { player.playUpNext() } },
                           onDismiss: { withAnimation(.snappy) { player.dismissUpNext() } })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: player.upNext?.id)
        .background { PlayerBackdrop(artworkID: book.artworkID) }
    }

    private func resizableContent(for book: Book) -> some View {
        GeometryReader { geometry in
            if geometry.size.width >= 560 {
                let shortWindow = geometry.size.height < 500
                HStack(spacing: 24) {
                    VStack(spacing: 12) {
                        artwork(for: book)
                            .frame(width: shortWindow
                                   ? min(200, geometry.size.width * 0.3, geometry.size.height * 0.4)
                                   : min(400, geometry.size.width * 0.36, geometry.size.height * 0.65))
                        if shortWindow {
                            ViewThatFits(in: .vertical) {
                                bookHeading(for: book)
                                ScrollView { bookHeading(for: book) }
                                    .scrollBounceBehavior(.basedOnSize)
                                    .scrollIndicators(.hidden)
                            }
                        }
                    }
                    .frame(maxWidth: shortWindow ? 300 : 400)
                    playbackColumn(for: book, showsHeading: !shortWindow, showsChapters: !shortWindow)
                }
                .padding(shortWindow ? 12 : 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        artwork(for: book)
                            .frame(width: min(300, max(120, geometry.size.height * 0.38),
                                              max(120, geometry.size.width - 72)))
                        bookHeading(for: book)
                        playbackControls(for: book)
                        routingControls(for: book)
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func playbackColumn(for book: Book, showsHeading: Bool, showsChapters: Bool) -> some View {
        Group {
            if showsChapters, !textSize.isAccessibilitySize {
                fixedPlaybackColumn(for: book, showsHeading: showsHeading, showsChapters: true)
            } else {
                ViewThatFits(in: .vertical) {
                    fixedPlaybackColumn(for: book, showsHeading: showsHeading, showsChapters: showsChapters)
                    // Very large text can scroll this pane while the artwork stays put.
                    ScrollView {
                        VStack(spacing: 12) {
                            if showsHeading { bookHeading(for: book) }
                            playbackControls(for: book)
                            routingControls(for: book)
                            if showsChapters { chapterShelf(for: book) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .frame(maxWidth: 460)
    }

    private func fixedPlaybackColumn(for book: Book, showsHeading: Bool, showsChapters: Bool) -> some View {
        VStack(spacing: showsHeading ? 20 : 12) {
            if showsHeading { bookHeading(for: book) }
            playbackControls(for: book)
            routingControls(for: book)
            if showsChapters, book.chapters.count > 1 {
                ScrollView { chapterShelf(for: book) }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 240)
                    .layoutPriority(-1)
                    .accessibilityIdentifier("PlayerChapterScrollView")
            }
        }
    }

    private func artwork(for book: Book) -> some View {
        ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 22, contentMode: .fit)
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.28), radius: 24, y: 14)
            .scaleEffect(player.isPlaying ? 1 : 0.92)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: player.isPlaying)
    }

    @ViewBuilder
    private func chapterShelf(for book: Book) -> some View {
        if book.chapters.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Chapters").font(.headline)
                    Spacer()
                    Button("See all") { sheet = .chapters }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                let current = player.currentChapterIndex ?? 0
                ForEach(Array(book.chapters.enumerated()).filter { abs($0.offset - current) <= 1 }, id: \.element.id) { index, chapter in
                    Button {
                        player.jump(to: chapter)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: index == current ? "waveform" : "play.circle")
                                .foregroundStyle(index == current ? Color.accentColor : .secondary)
                            Text(chapter.title).lineLimit(1)
                            Spacer()
                            Text(chapter.duration.clockString)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .padding(12)
                        .frame(minHeight: 44)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play chapter \(index + 1): \(chapter.title)")
                }
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("PlayerChapterShelf")
        }
    }

    private func bookHeading(for book: Book) -> some View {
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
    }

    private func playbackControls(for book: Book) -> some View {
        VStack(spacing: 0) {
            ScrubberView()
                .padding(.horizontal, 24)
            Text(bookLine(for: book))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 6)
            Color.clear.frame(height: 18)

            TransportControls(openSpeed: { sheet = .speed }, openSleep: { sheet = .sleep })
                .padding(.horizontal, 12)

        }
    }

    private func routingControls(for book: Book) -> some View {
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
            if let origin = player.jumpOrigin {
                Button {
                    player.undoJump()
                } label: {
                    Label("Back to \(jumpLabel(origin, in: book))", systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .padding(.vertical, 6)   // 44 pt tall: this is tapped in the car
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Undo jump")
                .accessibilityValue("Back to \(jumpLabel(origin, in: book))")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.snappy, value: player.jumpOrigin)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    /// "Ch. 3 · 4:12" — where Undo Jump goes back to (or the book time for a one-chapter book).
    private func jumpLabel(_ origin: BookPosition, in book: Book) -> String {
        if book.chapters.count > 1, let index = book.chapterIndex(trackIndex: origin.trackIndex, time: origin.time) {
            let intoChapter = max(0, origin.time - book.chapters[index].start)
            return "Ch. \(index + 1) · \(intoChapter.clockString)"
        }
        return book.absoluteOffset(trackIndex: origin.trackIndex, time: origin.time).clockString
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
/// A living backdrop for the player: a 3×3 mesh gradient sampled from the book's cover, its interior
/// points drifting slowly so the colors breathe. Falls back to the amber theme when there's no art.
struct PlayerBackdrop: View {
    let artworkID: String?
    @Environment(AppSettings.self) private var settings
    @State private var colors: [Color] = PlayerBackdrop.fallback

    static let fallback: [Color] = [
        Color(.sRGB, red: 1.00, green: 0.80, blue: 0.42), Color(.sRGB, red: 0.97, green: 0.66, blue: 0.28), Color(.sRGB, red: 0.90, green: 0.50, blue: 0.18),
        Color(.sRGB, red: 0.95, green: 0.58, blue: 0.20), Color(.sRGB, red: 0.86, green: 0.44, blue: 0.14), Color(.sRGB, red: 0.72, green: 0.34, blue: 0.10),
        Color(.sRGB, red: 0.80, green: 0.40, blue: 0.12), Color(.sRGB, red: 0.62, green: 0.30, blue: 0.09), Color(.sRGB, red: 0.45, green: 0.22, blue: 0.07),
    ]

    /// Heavier at the top (nav) and bottom (controls) so text stays legible over vibrant covers,
    /// lighter through the middle where the artwork sits.
    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: Color(.systemBackground).opacity(0.58), location: 0.0),
            .init(color: Color(.systemBackground).opacity(0.24), location: 0.42),
            .init(color: Color(.systemBackground).opacity(0.38), location: 0.72),
            .init(color: Color(.systemBackground).opacity(0.66), location: 1.0),
        ], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        if !settings.ambientPlayerBackground {
            Color(.systemBackground).ignoresSafeArea()
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                MeshGradient(width: 3, height: 3, points: Self.points(at: t), colors: colors)
                    .overlay(scrim)
                    .ignoresSafeArea()
            }
            .task(id: artworkID) {
            if let image = await ArtworkStore.shared.loadImage(for: artworkID),
               let sampled = Self.gridColors(from: image), sampled.count == 9 {
                withAnimation(.easeInOut(duration: 0.9)) { colors = sampled }
            } else {
                withAnimation(.easeInOut(duration: 0.9)) { colors = Self.fallback }
            }
        }
        }
    }

    /// 3×3 control points with the interior (and mid-edges) drifting on slow sines.
    static func points(at t: TimeInterval) -> [SIMD2<Float>] {
        let dx = Float(sin(t * 0.22)) * 0.07, dy = Float(cos(t * 0.17)) * 0.07
        let ex = Float(cos(t * 0.13)) * 0.04
        return [
            [0, 0], [0.5 + ex, 0], [1, 0],
            [0, 0.5 - ex], [0.5 + dx, 0.5 + dy], [1, 0.5 + ex],
            [0, 1], [0.5 - ex, 1], [1, 1],
        ]
    }

    /// Samples a cover into a 3×3 grid of colors, nudged toward vibrancy.
    static func gridColors(from image: UIImage) -> [Color]? {
        guard let cg = image.cgImage else { return nil }
        let n = 3
        var data = [UInt8](repeating: 0, count: n * n * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var colors: [Color] = []
        for i in 0..<(n * n) {
            var r = Double(data[i * 4]) / 255, g = Double(data[i * 4 + 1]) / 255, b = Double(data[i * 4 + 2]) / 255
            // gentle saturation/vibrancy lift so muddy covers still read as color
            let mean = (r + g + b) / 3
            r = min(1, mean + (r - mean) * 1.35); g = min(1, mean + (g - mean) * 1.35); b = min(1, mean + (b - mean) * 1.35)
            colors.append(Color(.sRGB, red: r, green: g, blue: b))
        }
        return colors
    }
}
