import SwiftUI
import ShelfKit

struct ListeningInsightsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var history = false
    @State private var estimates = false

    private var insights: ActivityInsights {
        let dates = library.visibleBooks.compactMap { book -> Date? in
            let p = library.progress(for: book.id)
            return p.isFinished ? p.finishedAt ?? p.lastPlayedAt : nil
        } + library.readingLog.map(\.finishedAt)
        return ActivityInsights(days: library.allDayActivity, sessions: library.sessions, finishes: dates)
    }

    var body: some View {
        StatCard("Your listening") {
            ActivityInsightsView(insights: insights, noun: "books")
            Divider()
            DisclosureGroup("Finish estimates", isExpanded: $estimates) {
                ForEach(library.inProgressBooks.prefix(5)) { book in
                    let p = library.progress(for: book.id)
                    let speed = max(0.5, Double(p.speed ?? settings.defaultSpeed))
                    let seconds = p.remaining(in: book) / speed
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title).font(.subheadline)
                        Text("About \(Durations.short(seconds)) left at \(speed.formatted())×")
                            .font(.caption).foregroundStyle(.secondary)
                        if let days = insights.daysToFinish(remainingSeconds: seconds) {
                            Text("Roughly \(days) days at your recent pace").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 3)
                }
                Text("Based on playback speed and listening over the last 28 calendar days. Silence skipping can shorten this.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Session history", systemImage: "clock.arrow.circlepath") { history = true }
        }.sheet(isPresented: $history) { ListeningSessionHistory() }
    }
}

private struct ListeningSessionHistory: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.sessions.sorted { $0.startedAt > $1.startedAt }) { session in
                        let book = library.book(id: session.bookID) ?? library.visibleBooks.first { $0.syncKey == session.bookKey }
                        Button {
                            if let book { player.load(book, autoplay: true); dismiss() }
                        } label: {
                            ActivitySessionRow(title: session.bookTitle, date: session.startedAt, seconds: session.activeSeconds)
                        }.disabled(book == nil)
                    }
                } footer: { Text("Sessions from this device. Tap a book to resume listening at its current saved position.") }
            }
            .overlay { if library.sessions.isEmpty { ContentUnavailableView("No sessions yet", systemImage: "clock") } }
            .navigationTitle("Session history")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
