import SwiftUI
import os

@main
struct EarmarkApp: App {
    private let environment = AppEnvironment.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.library)
                .environment(environment.player)
                .environment(environment.settings)
                .environment(environment.downloads)
                .onOpenURL { url in
                    Logger.library.info("[app] open url \(url.lastPathComponent, privacy: .public)")
                    environment.library.addOpenedFile(url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            Logger.ui.debug("[app] scene phase \(String(describing: phase), privacy: .public)")
            if phase == .background || phase == .inactive {
                environment.player.persistPosition()
                environment.library.save()
            }
        }
    }
}
