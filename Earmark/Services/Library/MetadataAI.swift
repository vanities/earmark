import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device metadata cleanup using Apple's Foundation Models framework (iOS 26+). Private, offline,
/// free — no API key. Falls back to "unavailable" on devices without Apple Intelligence.
@MainActor
enum MetadataAI {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// A short reason the feature is off, for the UI. Nil when available.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This device doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use this."
            case .unavailable(.modelNotReady): return "The on-device model is still downloading. Try again soon."
            case .unavailable: return "The on-device model isn't available right now."
            }
        }
        #endif
        return "Requires iOS 26 and Apple Intelligence."
    }

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    @Generable
    struct BookInfo {
        @Guide(description: "The book's title only — no series name, volume number, author, or edition tags like (Unabridged)")
        var title: String
        @Guide(description: "The author's full name, or an empty string if it can't be determined")
        var author: String
        @Guide(description: "The name of the series this book belongs to, or an empty string if it's a standalone")
        var series: String
        @Guide(description: "This book's number within its series, or 0 if it isn't part of one")
        var seriesIndex: Double
        @Guide(description: "The narrator's name if identifiable, otherwise an empty string")
        var narrator: String
    }
    #endif

    /// Suggests corrected metadata from a book's file path and current fields. Returns only the
    /// fields worth changing (as a BookMetadataOverride), or nil if unavailable / on error.
    static func suggest(for book: Book) async -> BookMetadataOverride? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .available = SystemLanguageModel.default.availability {
            let prompt = """
            You are cleaning up audiobook metadata. From the signals below, identify the real book \
            title (with no series name, volume number, author, or edition text), the author, the \
            series and this book's number in it if any, and the narrator if you can tell.

            File path: \(book.relativePath)
            Currently shown title: \(book.title)
            Currently shown author: \(book.author ?? "unknown")
            Currently shown series: \(book.series ?? "none")
            """
            do {
                let session = LanguageModelSession()
                let info = try await session.respond(to: prompt, generating: BookInfo.self).content
                var override = BookMetadataOverride()
                let title = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty, title.lowercased() != book.title.lowercased() { override.title = title }
                let author = info.author.trimmingCharacters(in: .whitespacesAndNewlines)
                if author != (book.author ?? "") { override.author = author }
                let series = info.series.trimmingCharacters(in: .whitespacesAndNewlines)
                if series != (book.series ?? "") { override.series = series }
                if info.seriesIndex > 0, info.seriesIndex != book.seriesIndex { override.seriesIndex = info.seriesIndex }
                let narrator = info.narrator.trimmingCharacters(in: .whitespacesAndNewlines)
                if !narrator.isEmpty, narrator != (book.narrator ?? "") { override.narrator = narrator }
                Logger.library.info("[ai] metadata suggestion for \(book.title, privacy: .public)")
                return override.isEmpty ? BookMetadataOverride() : override
            } catch {
                Logger.library.error("[ai] metadata suggest failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        #endif
        return nil
    }
}
