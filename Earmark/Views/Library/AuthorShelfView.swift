import SwiftUI
import ShelfKit

/// An author's page, laid out as Mango's series page (`ShelfPageHeader`, a ••• menu), with the
/// books arranged by sets of work (series in chronological order, then standalones), or by Title
/// or Recent.
struct AuthorShelfView: View {
    enum Arrangement: String, CaseIterable, Identifiable {
        case sets = "Sets", title = "Title", recent = "Recent"
        var id: Self { self }
    }

    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    let group: LibraryGroup
    let openPlayer: () -> Void
    @State private var arrangement: Arrangement = .sets

    /// Live books for this author (the group snapshot can go stale after a rescan).
    private var books: [Book] { library.live(group).books }

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
        let ordered = sets
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    // Resume or start in reading order, whichever way the books below are arranged.
                    ShelfPageHeader(title: group.title, books: ordered.flatMap(\.books), openPlayer: openPlayer)
                    Picker("Arrange", selection: $arrangement) {
                        ForEach(Arrangement.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                switch arrangement {
                case .sets:
                    ForEach(ordered) { section in
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShelfPageMenu(name: "Author", books: books)
            }
        }
    }
}
