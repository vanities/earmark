import AppIntents
import Foundation

/// One audiobook, exposed to Siri and Shortcuts so phrases like "Play <book> in Earmark" work.
struct BookEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audiobook"
    static let defaultQuery = BookEntityQuery()

    let id: String
    let title: String
    let author: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(author)")
    }
}

struct BookEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [BookEntity] {
        let library = AppEnvironment.shared.library
        return identifiers.compactMap { id in
            library.book(id: id).map { BookEntity(id: $0.id, title: $0.title, author: $0.displayAuthor) }
        }
    }

    /// Match a spoken/typed title to library books.
    @MainActor func entities(matching string: String) async throws -> [BookEntity] {
        let needle = string.lowercased()
        return AppEnvironment.shared.library.visibleBooks
            .filter { $0.title.lowercased().contains(needle) || ($0.author?.lowercased().contains(needle) ?? false) }
            .prefix(20)
            .map { BookEntity(id: $0.id, title: $0.title, author: $0.displayAuthor) }
    }

    /// Continue-listening books surface as suggestions in Shortcuts.
    @MainActor func suggestedEntities() async throws -> [BookEntity] {
        let library = AppEnvironment.shared.library
        let inProgress = library.inProgressBooks
        let pool = inProgress.isEmpty ? library.sorted(library.visibleBooks, by: .recent) : inProgress
        return pool.prefix(10).map { BookEntity(id: $0.id, title: $0.title, author: $0.displayAuthor) }
    }
}

/// "Resume my audiobook" — picks up the current or most recent book. Audio starts without pulling
/// the app to the foreground.
struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Resume your current audiobook.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppEnvironment.shared.resumePlayback()
        return .result()
    }
}

/// "Play <book> in Earmark".
struct PlayBookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Audiobook"
    static let description = IntentDescription("Play a specific audiobook in Earmark.")

    @Parameter(title: "Audiobook")
    var book: BookEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let env = AppEnvironment.shared
        guard let match = env.library.book(id: book.id) else {
            throw $book.needsValueError("Which audiobook?")
        }
        env.player.load(match, autoplay: true)
        return .result()
    }

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$book)") }
}

struct EarmarkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BookmarkListeningIntent(), phrases: ["Bookmark this in \(.applicationName)"], shortTitle: "Bookmark This Spot", systemImageName: "bookmark")
        AppShortcut(intent: ListeningSleepIntent(), phrases: ["Set a sleep timer in \(.applicationName)"], shortTitle: "Sleep Timer", systemImageName: "moon")
        AppShortcut(intent: ApplyListeningPresetIntent(), phrases: ["Apply a listening preset in \(.applicationName)"], shortTitle: "Listening Preset", systemImageName: "slider.horizontal.3")
        AppShortcut(
            intent: ResumeListeningIntent(),
            phrases: [
                "Resume my audiobook in \(.applicationName)",
                "Continue listening in \(.applicationName)",
                "Keep listening in \(.applicationName)"
            ],
            shortTitle: "Resume Listening",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)"
            ],
            shortTitle: "Play Audiobook",
            systemImageName: "book.fill"
        )
    }
}

enum ListeningPresetChoice: String, AppEnum {
    case driving, bedtime
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Listening preset"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.driving: "Driving", .bedtime: "Bedtime"]
}

struct ApplyListeningPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Listening Preset"
    @Parameter(title: "Preset") var preset: ListeningPresetChoice
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        guard env.player.book != nil else { return .result(dialog: "Open an audiobook first.") }
        guard let value = env.settings.listeningPresets.first(where: { $0.id == preset.rawValue }) else {
            return .result(dialog: "That preset is unavailable.")
        }
        env.player.applyPreset(value)
        return .result(dialog: "Applied \(value.name).")
    }
}

struct BookmarkListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Bookmark This Spot"
    @Parameter(title: "Note", default: "") var note: String
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        guard let book = env.player.book else { return .result(dialog: "Open an audiobook first.") }
        env.library.addBookmark(for: book, offset: env.player.bookElapsed, note: note)
        return .result(dialog: "Bookmark saved.")
    }
}

struct ListeningSleepIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    @Parameter(title: "Minutes", default: 20) var minutes: Int
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = AppEnvironment.shared.player
        guard player.book != nil else { return .result(dialog: "Open an audiobook first.") }
        guard (1...180).contains(minutes) else { throw $minutes.needsValueError("Choose 1 to 180 minutes.") }
        player.setSleepTimer(.duration(Double(minutes * 60)))
        return .result(dialog: "Sleep timer set for \(minutes) minutes.")
    }
}
