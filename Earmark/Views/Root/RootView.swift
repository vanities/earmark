import SwiftUI
import ShelfKit

struct RootView: View {
    enum AppTab: Hashable { case library, stats, folders, settings }

    @Environment(PlayerEngine.self) private var player
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .library
    @State private var showPlayer = false

    var body: some View {
        Group {
            if player.hasBook {
                tabs.tabViewBottomAccessory {
                    MiniPlayerView { showPlayer = true }
                }
            } else {
                tabs
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
        }
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
            Tab("Folders", systemImage: "folder.fill", value: .folders) {
                FoldersView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
