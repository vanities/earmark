import Foundation

/// Pure logic for cover choices across devices, kept apart from iCloud and the art cache so it can be
/// unit-tested (like `ProgressSync`). Choices are keyed by `Book.syncKey`; the newest one wins.
enum CoverSync {
    /// Local choices with any newer cloud ones folded in. A tie keeps the local choice.
    static func merged(local: [String: CoverChoice], cloud: [String: CoverChoice]) -> [String: CoverChoice] {
        var result = local
        for (key, remote) in cloud {
            if let mine = result[key], mine.chosenAt >= remote.chosenAt { continue }
            result[key] = remote
        }
        return result
    }

    /// Choices from the first sync format (syncKey → cover URL). They're dated in the distant past, so
    /// any choice made since — on any device — beats them.
    static func legacyChoices(_ urls: [String: String]) -> [String: CoverChoice] {
        urls.mapValues { CoverChoice(kind: .online, url: $0, chosenAt: .distantPast) }
    }

    /// One step that brings a book's cover on this device in line with its synced choice.
    enum Action: Equatable {
        /// Fetch the chosen cover and keep it under `artworkID`.
        case download(URL, artworkID: String)
        /// An older build already stored this cover under another id: move it instead of downloading it again.
        case adopt(from: String, to: String)
        /// The user went back to the book's own art, maybe on another device.
        case removeCustom
    }

    /// What this device should do, per book ID, so every cover matches its choice. `hasImage` says
    /// whether a thumbnail is in the art cache, which iOS can purge and Settings can rebuild.
    static func plan(books: [Book], choices: [String: CoverChoice], customArtwork: [String: String],
                     hasImage: (String) -> Bool) -> [String: Action] {
        var actions: [String: Action] = [:]
        for book in books {
            guard let choice = choices[book.syncKey] else { continue }
            let current = customArtwork[book.id]
            switch choice.kind {
            case .online:
                guard let url = choice.url.flatMap(URL.init(string:)) else { continue }
                let wanted = ArtworkStore.customID(for: book.id, sourceURL: url)
                if current == wanted, hasImage(wanted) { continue }
                if choice.chosenAt == .distantPast, let current, current != wanted, hasImage(current) {
                    actions[book.id] = .adopt(from: current, to: wanted)
                } else {
                    actions[book.id] = .download(url, artworkID: wanted)
                }
            case .original:
                if current != nil { actions[book.id] = .removeCustom }
            case .deviceOnly:
                break
            }
        }
        return actions
    }
}
