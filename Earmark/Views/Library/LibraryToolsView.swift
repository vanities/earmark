import SwiftUI
import ShelfKit

struct LibraryToolsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(DownloadManager.self) private var transfers
    @Environment(PlayerEngine.self) private var player
    private var tools: Binding<LibraryToolsState> {
        Binding(get: { library.tools }, set: { library.tools = $0; library.save() })
    }
    var body: some View {
        List {
            NavigationLink("Prepare for a trip") {
                TripPreparationView(items: library.toolItems, groups: library.tripGroups,
                                    check: library.checkOffline, download: download)
            }
            NavigationLink("Smart lists") {
                SmartShelvesView(items: library.toolItems, state: tools, open: open)
            }
            NavigationLink("New arrivals") {
                NewArrivalsView(items: library.toolItems, state: tools, download: download, open: open)
            }
            NavigationLink("Arrange books and tracks") { GroupingEditorView() }
            NavigationLink("Backup and restore") { LibraryBackupView() }
            NavigationLink("Reconnect a folder") { ReconnectLibraryView() }
        }
        .navigationTitle("Library tools")

    }
    private func open(_ key: String) {
        if let book = library.visibleBooks.first(where: { $0.syncKey == key }) { player.load(book, autoplay: true) }
    }
    private func download(_ keys: Set<String>) async -> String {
        var requested = 0, ready = 0, unavailable = 0
        for key in keys {
            if await library.checkOffline(key: key) == .ready { ready += 1; continue }
            if let book = library.visibleBooks.first(where: { $0.syncKey == key }), let source = library.nasCopy(of: book) {
                transfers.download(source)
                requested += 1
            } else { unavailable += 1 }
        }
        return "\(requested) downloads requested; \(ready) already ready."
            + (unavailable > 0 ? " \(unavailable) need attention in Files or Sources." : " Check Sources for transfer progress, then verify here.")
    }
}
