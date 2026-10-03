import SwiftUI

/// Which book "Add to List…" is for — set from any book's menu, the sheet shown at the root.
@MainActor @Observable
final class ListPicking {
    var book: Book?
}

/// Every list, and a way to start one.
struct ListsView: View {
    @Environment(LibraryModel.self) private var library
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        List {
            if library.bookLists.isEmpty {
                ContentUnavailableView("No Lists Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Make one here, or choose Add to List… on any book."))
            }
            ForEach(library.bookLists) { list in
                NavigationLink {
                    BookListView(listID: list.id)
                } label: {
                    LabeledContent(list.name, value: "\(list.items.count)")
                }
            }
            .onDelete { offsets in
                for offset in offsets { library.deleteList(library.bookLists[offset].id) }
            }
        }
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New List", systemImage: "plus") { naming = true }
            }
        }
        .alert("New List", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { library.createList(named: name) }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

/// One list, in your order. A book opens its page.
struct BookListView: View {
    let listID: UUID

    @Environment(LibraryModel.self) private var library
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let list = library.bookList(id: listID)
        List {
            if let list {
                if list.items.isEmpty {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "text.badge.plus",
                                           description: Text("Choose Add to List… on a book."))
                }
                ForEach(library.entries(of: list)) { entry in
                    row(entry)
                }
                .onMove { library.moveInList(listID, from: $0, to: $1) }
                .onDelete { offsets in
                    let entries = library.entries(of: list)
                    for offset in offsets { library.removeFromList(listID, key: entries[offset].key) }
                }
            }
        }
        .navigationTitle(list?.name ?? "List")
        .toolbar {
            OverflowToolbar {
                Button("Rename…", systemImage: "pencil") {
                    newName = list?.name ?? ""
                    renaming = true
                }
                EditButton()
            }
        }
        .alert("Rename List", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { library.renameList(listID, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(_ entry: LibraryModel.ListEntry) -> some View {
        switch entry {
        case .book(let book):
            // A value link here went nowhere: this list is pushed by a view link, and the stack's
            // Book destination didn't reach it. A view link always does.
            NavigationLink {
                BookDetailView(book: book, openPlayer: {})
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(artworkID: book.artworkID, title: book.title, cornerRadius: 5)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).lineLimit(1)
                        Text(book.displayAuthor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        case .missing:
            VStack(alignment: .leading, spacing: 2) {
                Text("Not in the library right now").lineLimit(1)
                Text("Comes back when its folder does").font(.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Add to List…: tick the lists a book belongs on, or start a new one.
struct ListPickerView: View {
    let book: Book

    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Form {
                if !library.bookLists.isEmpty {
                    Section("Lists") {
                        ForEach(library.bookLists) { list in
                            let listed = library.isListed(book, in: list.id)
                            Button {
                                if listed { library.removeFromList(list.id, key: book.syncKey) } else { library.addToList(list.id, book) }
                            } label: {
                                HStack {
                                    Text(list.name).foregroundStyle(.primary)
                                    Spacer()
                                    if listed { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                }
                Section("New list") {
                    TextField("Name, like “Up next”", text: $newName)
                        .onSubmit(create)
                    Button("Create and Add", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Add \(book.title) to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let id = library.createList(named: name)
        library.addToList(id, book)
        newName = ""
    }
}
