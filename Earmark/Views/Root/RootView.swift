import SwiftUI

struct RootView: View {
    enum AppTab: Hashable { case library, folders, settings }

    @Environment(PlayerEngine.self) private var player
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
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                LibraryView(openPlayer: { showPlayer = true })
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
