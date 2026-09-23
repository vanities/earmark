import SwiftUI
import os
import ShelfKit

/// What a screen deep in a tab can ask of the root's chrome — for now, putting the mini player
/// away while a source's bottom bar is out (select mode), as Mango's has nothing under it.
@MainActor @Observable
final class RootChrome {
    var hidesMiniPlayer = false
}

struct RootView: View {
    enum AppTab: Hashable { case library, stats, sources, settings }

    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppLock.self) private var lock
    @Environment(ListPicking.self) private var listPicking
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .library
    @State private var showPlayer = false
    @State private var chrome = RootChrome()

    var body: some View {
        Group {
            if #available(iOS 26.1, *) {
                // One TabView with or without a book: switching the accessory keeps each tab's place.
                tabs.tabViewBottomAccessory(isEnabled: player.hasBook && !chrome.hidesMiniPlayer) {
                    MiniPlayerView { showPlayer = true }
                }
            } else if player.hasBook {
                tabs.tabViewBottomAccessory {
                    MiniPlayerView { showPlayer = true }
                }
            } else {
                tabs
            }
        }
        .environment(chrome)
        .sheet(isPresented: $showPlayer) {
            PlayerView()
        }
        // Add to List… from any book's menu, wherever it was opened.
        .sheet(item: Bindable(listPicking).book) { ListPickerView(book: $0) }
        // The phone's own scene phase, not the app's (CarPlay keeps that active). The lock draws
        // in a window of its own, so it covers the player sheet too; `initial` puts it up at launch.
        .onChange(of: scenePhase, initial: true) { _, phase in
            lock.sceneChanged(to: phase)
            if phase == .active {
                // Back from Files, say, where books were just dropped into Earmark's folder.
                library.sceneBecameActive()
                playOpenedBook()
            }
        }
        // "Open With Earmark" on an iPad can reach Earmark while this window is in the background
        // and another is coming forward: only a window in front plays it; one coming forward later
        // picks it up above.
        .onChange(of: library.openedBook?.id) { _, id in
            guard id != nil, scenePhase == .active else { return }
            playOpenedBook()
        }
    }

    /// A file just opened with Earmark: play it with the player up. Behind the lock it's only
    /// loaded, so nothing is heard before the library is unlocked; one that's been waiting (no
    /// window came forward) is dropped rather than starting out of the blue later.
    private func playOpenedBook() {
        guard let book = library.openedBook else { return }
        library.openedBook = nil
        guard Date().timeIntervalSince(library.openedBookAt) < 30 else {
            Logger.ui.notice("[ui] not playing \(book.title, privacy: .public): opened too long ago")
            return
        }
        Logger.ui.info("[ui] playing opened \(book.title, privacy: .public)")
        player.load(book, autoplay: !lock.isLocked)
        selectedTab = .library
        showPlayer = true
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                LibraryView(openPlayer: { showPlayer = true })
            }
            Tab("Stats", systemImage: "chart.bar.fill", value: .stats) {
                StatsView()
            }
            Tab("Sources", systemImage: "folder.fill", value: .sources) {
                SourcesView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
