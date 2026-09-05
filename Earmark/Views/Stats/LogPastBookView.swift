import SwiftUI

/// Add or edit a book finished before/outside Earmark, so it counts in Stats.
struct LogPastBookView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    let entry: ReadingLogEntry?

    @State private var title = ""
    @State private var author = ""
    @State private var finishedAt = Date.now
    @State private var rating: Int?
    @State private var hoursText = ""

    private var isEditing: Bool { entry != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Book") {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                }
                Section("Finished") {
                    DatePicker("Date", selection: $finishedAt, in: ...Date.now, displayedComponents: .date)
                }
                Section("Rating") {
                    StarRatingPicker(rating: $rating)
                }
                Section {
                    TextField("Length in hours (optional)", text: $hoursText).keyboardType(.decimalPad)
                } footer: {
                    Text("Adds to your total listening time in Stats. Leave blank if you don't know it.")
                }
                if isEditing {
                    Section {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            if let entry { library.removeReadingLogEntry(entry.id) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Past Book" : "Log a Past Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let entry else { return }
        title = entry.title
        author = entry.author ?? ""
        finishedAt = entry.finishedAt
        rating = entry.rating
        hoursText = entry.hours.map { String(format: "%g", $0) } ?? ""
    }

    private func save() {
        let hours = Double(hoursText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let cleanAuthor = author.trimmingCharacters(in: .whitespaces)
        if var entry {
            entry.title = cleanTitle
            entry.author = cleanAuthor.isEmpty ? nil : cleanAuthor
            entry.finishedAt = finishedAt
            entry.rating = rating
            entry.hours = hours
            library.updateReadingLogEntry(entry)
        } else {
            library.addReadingLogEntry(title: cleanTitle, author: cleanAuthor, finishedAt: finishedAt, rating: rating, hours: hours)
        }
        dismiss()
    }
}
