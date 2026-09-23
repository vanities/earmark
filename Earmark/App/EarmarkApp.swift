import SwiftUI
import os
import ShelfKit

@main
struct EarmarkApp: App {
    private let environment = AppEnvironment.shared
    @State private var listPicking = ListPicking()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.library)
                .environment(environment.player)
                .environment(environment.settings)
                .environment(environment.downloads)
                .environment(environment.lock)
                .environment(listPicking)
                // An opened file goes to the window already open, rather than iPadOS opening a
                // second Earmark window for it each time.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    if url.scheme == "earmark" {
                        Logger.library.info("[app] deep link \(url.absoluteString, privacy: .public)")
                        switch url.host {
                        case "resume": environment.resumePlayback()
                        case "book": if let id = url.pathComponents.last { environment.playBook(id: id) }
                        default: break
                        }
                        return
                    }
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
