import Foundation

extension LibraryState {
    /// Recreate a saved arrangement only on an untouched, unambiguously matching set of files.
    /// Existing listening state or arrangements win; the preview reports those unmatched books.
    mutating func preparePortableGrouping(_ old: LibraryState) {
        for saved in old.manualGroupings {
            let required = Dictionary(saved.groups.flatMap(\.tracks).map { ($0.relativePath, $0.fileSize) }, uniquingKeysWith: { first, _ in first })
            guard !required.isEmpty, required.count == saved.groups.flatMap(\.tracks).count else { continue }
            let candidates = sources.filter { source in
                guard !manualGroupings.contains(where: { $0.applies(to: source.id) }) else { return false }
                let files = Dictionary(books.filter { $0.sourceID == source.id }.flatMap(\.tracks).map { ($0.relativePath, $0.fileSize) }, uniquingKeysWith: { first, _ in first })
                return required.allSatisfy { $0.value > 0 && files[$0.key] == $0.value }
            }
            guard let primary = candidates.first,
                  candidates.count == 1 || (candidates.count == 2 && candidates.contains(where: { $0.kind == .appDocuments }) && candidates.contains(where: { $0.kind == .smb })) else { continue }
            let ids = Set(candidates.map(\.id))
            let before = books.filter { ids.contains($0.sourceID) }
            let affected = before.filter { !$0.tracks.allSatisfy { required[$0.relativePath] == nil } }
            guard affected.allSatisfy({ progress[$0.id] == nil && bookmarks[$0.id] == nil && metadataOverrides[$0.id] == nil
                && customArtwork[$0.id] == nil && coverChoices[$0.syncKey] == nil && !hiddenBookIDs.contains($0.id) && lastBookID != $0.id }) else { continue }
            var copies = ids.subtracting([primary.id])
            if primary.kind != .appDocuments { copies.formUnion(sources.filter { $0.kind == .appDocuments }.map(\.id)) }
            let originals = before.filter { $0.sourceID == primary.id }
            let groups = saved.groups.map { template -> Book in
                var group = ManualGrouping.rebase(template, source: primary.id)
                group.artworkID = originals.first { candidate in candidate.tracks.contains { track in group.tracks.contains { $0.relativePath == track.relativePath } } }?.artworkID
                return group
            }
            let rule = ManualGrouping(sourceID: primary.id, copySourceIDs: copies, original: originals, groups: groups, previous: originals)
            let after = candidates.flatMap { source in rule.applied(to: before.filter { $0.sourceID == source.id }, source: source.id) }
            regroup(from: before.filter { !after.contains($0) }, to: after.filter { !before.contains($0) })
            books.removeAll { ids.contains($0.sourceID) }
            books.append(contentsOf: after)
            manualGroupings.append(rule)
        }
    }
}
