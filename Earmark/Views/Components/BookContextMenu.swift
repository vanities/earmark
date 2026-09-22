import SwiftUI

/// Shared actions for a book: play, finish/reset, reveal, hide.
struct BookContextMenu: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(ListPicking.self) private var listPicking
    let book: Book

    var body: some View {
        let progress = library.progress(for: book.id)
        Button(progress.hasStarted && !progress.isFinished ? "Resume" : "Play", systemImage: "play.fill") {
            player.load(book, autoplay: true)
        }
        if progress.isFinished {
            Button("Start Over", systemImage: "arrow.counterclockwise") {
                library.resetProgress(book.id)
                player.load(book, autoplay: true, startAt: BookPosition(trackIndex: 0, time: 0))
            }
        } else {
            Button("Mark as Finished", systemImage: "checkmark.circle") {
                library.markFinished(book.id)
                if player.book?.id == book.id { player.pause() }
            }
            if progress.hasStarted {
                Button("Reset Progress", systemImage: "arrow.counterclockwise") {
                    library.resetProgress(book.id)
                    if player.book?.id == book.id {
                        player.load(book, autoplay: false, startAt: BookPosition(trackIndex: 0, time: 0))
                    }
                }
            }
        }
        Button("Add to List…", systemImage: "text.badge.plus") { listPicking.book = book }
        Divider()
        if let copy = library.downloadedCopy(of: book) {
            // Listened to it, done with it: give the space back; it plays from the NAS again.
            // Not while it's playing — a book that's only loaded (finished, paused) can go.
            if !(player.isPlaying && player.book?.id == copy.id) {
                Button("Remove Download (\(copy.totalBytes.byteCountString))", systemImage: "trash") {
                    player.removeDownloads([copy], in: library)
                }
            }
        } else if library.isRemote(book) {
            Button("Download to iPhone", systemImage: "arrow.down.circle") { downloads.download(book) }
        } else if library.source(for: book)?.kind == .folder {
            Button("Move into Earmark", systemImage: "arrow.right.doc.on.clipboard") { downloads.move(book) }
        }
        if !library.isRemote(book) {
            Button("Show in Files", systemImage: "folder") {
                library.revealInFiles(book)
            }
        }
        if library.hiddenBookIDs.contains(book.id) {
            Button("Unhide", systemImage: "eye") { library.setHidden(false, bookID: book.id) }
        } else {
            Button("Hide from Library", systemImage: "eye.slash") { library.setHidden(true, bookID: book.id) }
        }
    }
}
