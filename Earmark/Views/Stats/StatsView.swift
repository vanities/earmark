import SwiftUI

struct StatsView: View {
    @Environment(LibraryModel.self) private var library
    @State private var showLogPast = false
    @State private var editingEntry: ReadingLogEntry?

    var body: some View {
        NavigationStack {
            let stats = library.readingStats
            Group {
                if stats.isEmpty {
                    ContentUnavailableView {
                        Label("No Finished Books Yet", systemImage: "books.vertical")
                    } description: {
                        Text("Mark a book finished, or log books you read before Earmark, and your reading history shows up here.")
                    } actions: {
                        Button("Log a Past Book", systemImage: "plus") { showLogPast = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        summarySection(stats)
                        yearsSection(stats)
                        if !stats.topAuthors.isEmpty { authorsSection(stats) }
                        if !library.readingLog.isEmpty { logSection }
                    }
                }
            }
            .navigationTitle("Stats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log a Past Book", systemImage: "plus") { showLogPast = true }
                }
            }
            .sheet(isPresented: $showLogPast) { LogPastBookView(entry: nil) }
            .sheet(item: $editingEntry) { LogPastBookView(entry: $0) }
        }
    }

    private func summarySection(_ stats: ReadingStats) -> some View {
        Section {
            HStack(spacing: 12) {
                stat("\(stats.totalBooks)", "Books")
                stat("\(Int(stats.totalHours.rounded()))", "Hours")
                stat("\(stats.thisYear)", "This Year")
                if let avg = stats.averageRating { stat(String(format: "%.1f", avg), "Avg ★") }
            }
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8))
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func yearsSection(_ stats: ReadingStats) -> some View {
        Section("Books per Year") {
            let maxCount = max(1, stats.years.map(\.count).max() ?? 1)
            ForEach(stats.years) { year in
                HStack(spacing: 10) {
                    Text(String(year.year)).font(.subheadline.monospacedDigit()).frame(width: 46, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.tint.opacity(year.year == stats.bestYear?.year ? 1 : 0.55))
                            .frame(width: max(6, geo.size.width * CGFloat(year.count) / CGFloat(maxCount)))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 18)
                    Text("\(year.count)").font(.subheadline.monospacedDigit().weight(.medium)).frame(width: 34, alignment: .trailing)
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    private func authorsSection(_ stats: ReadingStats) -> some View {
        Section("Most Read Authors") {
            ForEach(stats.topAuthors.prefix(5)) { entry in
                HStack {
                    Text(entry.author).lineLimit(1)
                    Spacer()
                    Text("\(entry.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private var logSection: some View {
        Section("Logged Past Books") {
            ForEach(library.readingLog.sorted { $0.finishedAt > $1.finishedAt }) { entry in
                Button {
                    editingEntry = entry
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).foregroundStyle(.primary).lineLimit(1)
                            HStack(spacing: 6) {
                                if let author = entry.author { Text(author).lineLimit(1) }
                                Text(entry.finishedAt, format: .dateTime.year())
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let rating = entry.rating { StarsView(rating: rating).font(.caption2) }
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { library.removeReadingLogEntry(entry.id) }
                }
            }
        }
    }
}

/// Read-only star row.
struct StarsView: View {
    let rating: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .foregroundStyle(i <= rating ? .yellow : .secondary)
            }
        }
    }
}

/// Tappable star rating used in the finish sheet and the past-book form.
struct StarRatingPicker: View {
    @Binding var rating: Int?
    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: (rating ?? 0) >= i ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle((rating ?? 0) >= i ? .yellow : .secondary)
                    .onTapGesture { rating = (rating == i) ? nil : i }
            }
            if rating != nil {
                Button("Clear") { rating = nil }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
}
