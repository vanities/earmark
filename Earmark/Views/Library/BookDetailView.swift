import SwiftUI

struct BookDetailView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let openPlayer: () -> Void

    @State private var confirmDelete = false
    @State private var deleteErrors: [String] = []
    @State private var showCoverPicker = false
    @State private var showEditDetails = false
    @State private var showMarkFinished = false

    /// Always render the library's live copy so rescans show up.
    private var current: Book { library.book(id: book.id) ?? book }
    private var isCurrent: Bool { player.book?.id == book.id }

    var body: some View {
        let book = current
        let progress = library.progress(for: book.id)
        ScrollView {
            VStack(spacing: 20) {
                ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 18, contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 260)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    .padding(.top, 8)
                    .overlay(alignment: .bottomTrailing) {
                        if book.artworkID == nil {
                            Button {
                                showCoverPicker = true
                            } label: {
                                Label("Find Cover", systemImage: "photo.badge.magnifyingglass")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.glass)
                            .padding(10)
                        }
                    }

                VStack(spacing: 6) {
                    Text(book.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(book.displayAuthor)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if let series = book.series {
                        Text(book.seriesIndex.map { "\(series) · Book \(Self.format($0))" } ?? series)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    if let narrator = book.narrator {
                        Text("Narrated by \(narrator)")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    Text(metaLine(for: book))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    if let rating = progress.rating {
                        StarsView(rating: rating).font(.footnote)
                    }
                    if let server = library.server(for: book) {
                        RemoteBadge(serverName: server.name)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal)

                if library.isRemote(book) {
                    DownloadButton(book: book)
                        .padding(.horizontal, 24)
                } else if library.source(for: book)?.kind == .folder {
                    MoveButton(book: book)
                        .padding(.horizontal, 24)
                }

                Button {
                    if isCurrent, player.isPlaying {
                        player.pause()
                    } else {
                        player.load(book, autoplay: true)
                        openPlayer()
                    }
                } label: {
                    Label(playLabel(progress), systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)

                if progress.hasStarted, !progress.isFinished {
                    VStack(spacing: 6) {
                        ProgressBar(fraction: progress.fraction(of: book), height: 6)
                        HStack {
                            Text("\(Int((progress.fraction(of: book) * 100).rounded()))%")
                            Spacer()
                            Text("\(progress.remaining(in: book).shortDurationString) left")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                } else if progress.isFinished {
                    Label("Finished", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }

                ChapterListSection(book: book, progress: progress)
                    .padding(.horizontal)
            }
            .padding(.bottom, 32)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCoverPicker) {
            CoverPickerView(book: book)
        }
        .sheet(isPresented: $showEditDetails) {
            EditBookDetailsView(book: book)
        }
        .sheet(isPresented: $showMarkFinished) {
            MarkFinishedSheet(book: book)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    BookContextMenu(book: book)
                    Button("Edit Details…", systemImage: "pencil") { showEditDetails = true }
                    Button("Finished Date & Rating…", systemImage: "checkmark.seal") { showMarkFinished = true }
                    Button("Find Cover…", systemImage: "photo.badge.magnifyingglass") { showCoverPicker = true }
                    if library.hasCustomCover(book) {
                        Button("Use Original Cover", systemImage: "arrow.uturn.backward") { library.useOriginalCover(for: book) }
                    }
                    if !library.isRemote(book) {
                        Divider()
                        Button("Delete Files…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete \(book.tracks.count) file\(book.tracks.count == 1 ? "" : "s") from disk?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Files", role: .destructive) {
                if isCurrent { player.unload() }
                deleteErrors = library.deleteBookFiles(book)
                if deleteErrors.isEmpty { dismiss() }
            }
        } message: {
            Text("This permanently removes the audio from \(library.sourceName(for: book.sourceID)) › \(book.relativePath). It cannot be undone.")
        }
        .alert("Some files couldn't be deleted", isPresented: Binding(get: { !deleteErrors.isEmpty }, set: { if !$0 { deleteErrors = [] } })) {
            Button("OK") {}
        } message: {
            Text(deleteErrors.joined(separator: "\n"))
        }
    }

    private func playLabel(_ progress: PlaybackProgress) -> String {
        if isCurrent, player.isPlaying { return "Pause" }
        if progress.isFinished { return "Listen Again" }
        if progress.hasStarted {
            if let chapter = current.chapter(at: progress.trackIndex, time: progress.time), current.chapters.count > 1 {
                return "Resume · \(chapter.title)"
            }
            return "Resume"
        }
        return "Play"
    }

    private func metaLine(for book: Book) -> String {
        var parts = ["\(book.chapters.count) chapter\(book.chapters.count == 1 ? "" : "s")", book.totalDuration.shortDurationString, book.formatLabel]
        if let year = book.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    static func format(_ index: Double) -> String {
        index.rounded() == index ? String(Int(index)) : String(index)
    }
}

struct ChapterListSection: View {
    @Environment(PlayerEngine.self) private var player
    let book: Book
    let progress: PlaybackProgress

    private var currentIndex: Int? {
        if player.book?.id == book.id { return player.currentChapterIndex }
        guard progress.hasStarted, !progress.isFinished else { return nil }
        return book.chapterIndex(trackIndex: progress.trackIndex, time: progress.time)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Chapters", count: book.chapters.count)
                .padding(.bottom, 6)
            ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                let isCurrent = currentIndex == index
                Button {
                    player.load(book, autoplay: true, startAt: BookPosition(trackIndex: chapter.trackIndex, time: chapter.start))
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, alignment: .trailing)
                        Text(chapter.title)
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        if isCurrent {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.tint)
                        }
                        Text(chapter.duration.clockString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }
}


struct RemoteBadge: View {
    let serverName: String
    var compact = false

    var body: some View {
        Label(compact ? "Remote" : "Remote · \(serverName)", systemImage: "externaldrive.connected.to.line.below")
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, compact ? 2 : 5)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Plays from \(serverName) over the network")
    }
}

struct DownloadButton: View {
    @Environment(DownloadManager.self) private var downloads
    let book: Book

    var body: some View {
        let job = downloads.job(for: book.id)
        VStack(spacing: 8) {
            if let job, job.isActive {
                ProgressView(value: job.fraction) {
                    HStack {
                        Text(job.state == .queued ? "Waiting to download…" : "Downloading to this iPhone…")
                        Spacer()
                        Text("\(Int(job.fraction * 100))%").monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button("Cancel Download", role: .cancel) { downloads.cancel(job.id) }
                    .font(.caption)
            } else {
                Button {
                    downloads.download(book)
                } label: {
                    Label(job?.state == .failed ? "Retry Download" : "Download to iPhone", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                if let error = job?.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Keeps a copy in On My iPhone › Earmark (\(book.totalBytes.byteCountString)) so it plays without the NAS.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}


struct MoveButton: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryModel.self) private var library
    let book: Book

    var body: some View {
        let job = downloads.job(for: book.id)
        VStack(spacing: 8) {
            if let job, job.isActive {
                ProgressView(value: job.fraction) {
                    HStack {
                        Text(job.state == .queued ? "Waiting to move…" : "Moving into Earmark…")
                        Spacer()
                        Text("\(Int(job.fraction * 100))%").monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    downloads.move(book)
                } label: {
                    Label(job?.state == .failed ? "Retry Move" : "Move into Earmark", systemImage: "arrow.right.doc.on.clipboard")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                if let error = job?.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Moves the files from \(library.sourceName(for: book.sourceID)) into On My iPhone › Earmark (\(book.totalBytes.byteCountString)); progress carries over.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
