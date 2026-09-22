import SwiftUI
import ShelfKit

/// What a screen deep in a tab can ask of the root's chrome — for now, putting the mini player
/// away while a source's bottom bar is out (select mode), as Mango's has nothing under it.
@MainActor @Observable
final class RootChrome {
    var hidesMiniPlayer = false
}

struct RootView: View {
    enum AppTab: Hashable { case library, stats, sources, settings }

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
        .onChange(of: scenePhase, initial: true) { _, phase in lock.sceneChanged(to: phase) }
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
