import SwiftUI
import ShelfKit

/// An author's books arranged by sets of work (series in chronological order, then standalones),
/// with Title and Recent as alternatives.
struct AuthorShelfView: View {
    enum Arrangement: String, CaseIterable, Identifiable {
        case sets = "Sets", title = "Title", recent = "Recent"
        var id: Self { self }
    }

    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    let group: LibraryGroup
    @State private var arrangement: Arrangement = .sets

    /// Live books for this author (the group snapshot can go stale after a rescan).
    private var books: [Book] {
        let key = group.id.replacingOccurrences(of: "author:", with: "")
        let live = library.visibleBooks.filter { ($0.author?.normalizedForMatching ?? "") == key }
        return live.isEmpty ? group.books : live
    }

    /// Series sections ordered by the earliest known year, then name; standalones last.
    private var sets: [LibraryGroup] {
        let sections = library.groups(.series, from: books)
        func year(_ section: LibraryGroup) -> Int { section.books.compactMap(\.year).min() ?? Int.max }
        let series = sections.filter { $0.id != "series:none" }.sorted { a, b in
            if year(a) != year(b) { return year(a) < year(b) }
            return a.title.naturallyPrecedes(b.title)
        }
        let standalone = sections.filter { $0.id == "series:none" }.map { section in
            LibraryGroup(id: section.id, title: "Standalone", subtitle: section.subtitle, books: library.sorted(section.books, by: .title))
        }
        return series + standalone
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                Picker("Arrange", selection: $arrangement) {
                    ForEach(Arrangement.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)

                switch arrangement {
                case .sets:
                    ForEach(sets) { section in
                        BookGridSection(title: section.title, books: section.books, layout: settings.libraryLayout)
                    }
                case .title:
                    BookGridSection(title: "All Books", books: library.sorted(books, by: .title), layout: settings.libraryLayout)
                case .recent:
                    BookGridSection(title: "Recently Played", books: library.sorted(books, by: .recent), layout: settings.libraryLayout)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.large)
    }
}
