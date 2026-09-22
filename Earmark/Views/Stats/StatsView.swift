import SwiftUI
import Charts
import UniformTypeIdentifiers
import ShelfKit

/// What you've listened to, laid out as Mango's Stats are: headline tiles, the yearly goal,
/// then a card for each way of looking at it. Built from the library, your places and the
/// books you've logged — Earmark records nothing extra and sends nothing anywhere.
struct StatsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var showLogPast = false
    @State private var editingEntry: ReadingLogEntry?
    @State private var showGoalEditor = false
    @State private var importing = false
    @State private var importResult: String?
    @State private var selectedYear: Int?          // nil = all time
    @State private var animate = false

    var body: some View {
        NavigationStack {
            let stats = library.readingStats
            ScrollView {
                if stats.isEmpty {
                    emptyState.frame(maxWidth: .infinity, minHeight: 460)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        headline(stats)
                        goalCard(stats)
                        if stats.years.count > 1 { yearFilter(stats) }
                        yearChart(stats)
                        if let dist = ratingDistribution(stats), dist.contains(where: { $0.count > 0 }) {
                            ratingsCard(dist, avg: stats.averageRating)
                        }
                        if !filteredAuthors(stats).isEmpty { authorsCard(stats) }
                        libraryCard
                        storageCard
                        loggedCard
                        footnote
                    }
                    .padding()
                }
            }
            .navigationTitle("Stats")
            // The same ••• menu as Mango's Stats, and the import only Earmark has.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Log a Book Read Elsewhere", systemImage: "plus") { showLogPast = true }
                        Button("Change Yearly Goal…", systemImage: "target") { showGoalEditor = true }
                        Button("Import Reading History…", systemImage: "square.and.arrow.down") { importing = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showLogPast) { LogPastBookView(entry: nil) }
            .sheet(item: $editingEntry) { LogPastBookView(entry: $0) }
            .sheet(isPresented: $showGoalEditor) { goalEditor }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .alert("Reading History", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
                Button("OK") {}
            } message: { Text(importResult ?? "") }
            .onAppear { withAnimation(.easeOut(duration: 0.8).delay(0.05)) { animate = true } }
        }
    }

    // MARK: Headline

    private func headline(_ stats: ReadingStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            StatTile("\(stats.totalBooks)", "Books finished", systemImage: "checkmark.circle.fill", tint: .green)
            // Books logged without a length count none; a "0h" headline would say nothing.
            if stats.totalHours >= 1 {
                StatTile("\(Int(stats.totalHours.rounded()))h", "Hours finished", systemImage: "clock.fill", tint: .blue)
            }
            StatTile("\(library.inProgressBooks.count)", "Listening now", systemImage: "headphones", tint: .red)
            StatTile("\(stats.topAuthors.count)", "Authors", systemImage: "person.2.fill", tint: .purple)
            if let avg = stats.averageRating {
                StatTile(avg.formatted(.number.precision(.fractionLength(1))), "Average rating", systemImage: "star.fill", tint: .yellow)
            }
            if let best = stats.bestYear {
                StatTile("\(best.count)", "Best year (\(String(best.year)))", systemImage: "trophy.fill", tint: .orange)
            }
        }
    }

    // MARK: Goal

    private func goalCard(_ stats: ReadingStats) -> some View {
        let goal = settings.yearlyBookGoal
        let done = stats.thisYear
        return StatCard("\(String(Calendar.current.component(.year, from: .now))) goal") {
            HStack(spacing: 18) {
                if goal > 0 {
                    GoalRing(done: done, goal: goal, noun: "books")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(done >= goal ? "Goal reached." : "\(goal - done) to go · \(Int(min(1, Double(done) / Double(goal)) * 100))% there")
                            .font(.headline)
                        Text(GoalRing.pace(done: done, goal: goal))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Change goal") { showGoalEditor = true }
                            .font(.caption)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(done) finished this year").font(.headline)
                        Button("Set a goal") { showGoalEditor = true }
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: Year filter

    private func yearFilter(_ stats: ReadingStats) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("All Time", selected: selectedYear == nil) { selectedYear = nil }
                ForEach(stats.years) { y in
                    filterChip(String(y.year), selected: selectedYear == y.year) {
                        selectedYear = selectedYear == y.year ? nil : y.year
                    }
                }
            }
        }
    }

    private func filterChip(_ label: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { tap() }
        } label: {
            Text(label).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Books per year (the best year stands out; a picked year is highlighted)

    private func yearChart(_ stats: ReadingStats) -> some View {
        StatCard("Finished per year") {
            Chart(stats.years.sorted { $0.year < $1.year }) { year in
                BarMark(
                    x: .value("Year", String(year.year)),
                    y: .value("Books", animate ? year.count : 0)
                )
                .foregroundStyle(barColor(year))
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text("\(year.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 170)
            .animation(.easeOut(duration: 0.7), value: animate)
            if let best = stats.bestYear {
                Text("Best year: \(String(best.year)), \(best.count) finished")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func barColor(_ year: ReadingStats.Year) -> AnyShapeStyle {
        if let sel = selectedYear { return year.year == sel ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.25)) }
        if year.year == library.readingStats.bestYear?.year { return AnyShapeStyle(Color.accentColor.gradient) }
        return AnyShapeStyle(Color.accentColor.opacity(0.6))
    }

    // MARK: Rating distribution

    private struct RatingBucket: Identifiable { let stars: Int; let count: Int; var id: Int { stars } }
    private func ratingDistribution(_ stats: ReadingStats) -> [RatingBucket]? {
        var counts = [Int: Int]()
        for book in library.visibleBooks {
            if let p = library.progress(for: book.id) as PlaybackProgress?, p.isFinished, let r = p.rating, inYear(p.finishedAt ?? p.lastPlayedAt) { counts[r, default: 0] += 1 }
        }
        for e in library.readingLog where inYear(e.finishedAt) { if let r = e.rating { counts[r, default: 0] += 1 } }
        let buckets = (1...5).map { RatingBucket(stars: $0, count: counts[$0] ?? 0) }
        return buckets.contains { $0.count > 0 } ? buckets : nil
    }

    private func ratingsCard(_ dist: [RatingBucket], avg: Double?) -> some View {
        StatCard("Ratings") {
            if let avg {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(avg, format: .number.precision(.fractionLength(1)))
                        .font(.title.weight(.semibold)).monospacedDigit()
                    Text("average across \(dist.reduce(0) { $0 + $1.count }) rated")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            let maxC = max(1, dist.map(\.count).max() ?? 1)
            ForEach(dist.reversed()) { b in
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= b.stars ? "star.fill" : "star")
                                .foregroundStyle(i <= b.stars ? .yellow : .secondary.opacity(0.3))
                        }
                    }.font(.caption2).frame(width: 86, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(.yellow.opacity(0.8))
                            .frame(width: max(b.count == 0 ? 0 : 8, geo.size.width * CGFloat(animate ? b.count : 0) / CGFloat(maxC)))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }.frame(height: 14)
                    Text("\(b.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Authors (respects the year filter)

    private func filteredAuthors(_ stats: ReadingStats) -> [ReadingStats.AuthorCount] {
        guard let year = selectedYear else { return stats.topAuthors }
        var counts: [String: Int] = [:]
        for book in library.visibleBooks {
            let p = library.progress(for: book.id)
            if p.isFinished, inYear(p.finishedAt ?? p.lastPlayedAt, year: year), let a = book.author { counts[a, default: 0] += 1 }
        }
        for e in library.readingLog where inYear(e.finishedAt, year: year) { if let a = e.author { counts[a, default: 0] += 1 } }
        return counts.map { ReadingStats.AuthorCount(author: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.author < $1.author }
    }

    private func authorsCard(_ stats: ReadingStats) -> some View {
        let authors = Array(filteredAuthors(stats).prefix(5))
        return StatCard(selectedYear.map { "Most read in \(String($0))" } ?? "Most read") {
            ForEach(authors) { a in
                HStack {
                    Text(a.author).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text("\(a.count)")
                        .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                if a.id != authors.last?.id { Divider() }
            }
        }
    }

    // MARK: The library, and where it lives (as in Mango)

    private var libraryCard: some View {
        let books = library.visibleBooks
        let finished = books.filter { library.isFinished($0) }.count
        let listening = library.inProgressBooks.count
        let notStarted = max(0, books.count - finished - listening)
        return StatCard("Library") {
            Chart {
                SectorMark(angle: .value("Finished", finished), innerRadius: .ratio(0.6), angularInset: 1.5)
                    .foregroundStyle(by: .value("State", "Finished"))
                SectorMark(angle: .value("Listening", listening), innerRadius: .ratio(0.6), angularInset: 1.5)
                    .foregroundStyle(by: .value("State", "Listening"))
                SectorMark(angle: .value("Not started", notStarted), innerRadius: .ratio(0.6), angularInset: 1.5)
                    .foregroundStyle(by: .value("State", "Not started"))
            }
            .chartLegend(position: .bottom, spacing: 8)
            .frame(height: 180)
        }
    }

    private var storageCard: some View {
        let local = library.visibleBooks.filter { !library.isRemote($0) }.reduce(Int64(0)) { $0 + $1.totalBytes }
        let remote = library.books.filter { library.isRemote($0) }.reduce(Int64(0)) { $0 + $1.totalBytes }
        return StatCard("Where it lives") {
            HStack(spacing: 16) {
                storageStat("On this iPhone", local, "iphone")
                storageStat("On the NAS", remote, "externaldrive.connected.to.line.below")
            }
        }
    }

    private func storageStat(_ label: String, _ bytes: Int64, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(bytes.byteCountString, systemImage: icon)
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Read elsewhere

    /// Books finished before Earmark, or outside it, logged so they count. Tap one to change it.
    private var loggedCard: some View {
        StatCard("Read elsewhere") {
            if library.readingLog.isEmpty {
                Text("Books you finished before Earmark, or outside it, can be logged here so they count.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(library.readingLog.sorted { $0.finishedAt > $1.finishedAt }.prefix(8)) { entry in
                    Button { editingEntry = entry } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let author = entry.author { Text(author).lineLimit(1) }
                                    Text(entry.finishedAt, format: .dateTime.year().month().day())
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let rating = entry.rating { StarsView(rating: rating).font(.caption2) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit…", systemImage: "pencil") { editingEntry = entry }
                        Button("Remove", systemImage: "trash", role: .destructive) { library.removeReadingLogEntry(entry.id) }
                    }
                }
            }
            Button { showLogPast = true } label: {
                Label("Log a book", systemImage: "plus.circle")
            }
            .padding(.top, 2)
        }
    }

    private var footnote: some View {
        Text("Worked out from your library, your places in each book and the books you've logged — finished books count their full length. Earmark collects no analytics and sends nothing anywhere; your places sync between your own devices through your own iCloud.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: Helpers

    private func inYear(_ date: Date?, year: Int? = nil) -> Bool {
        let target = year ?? selectedYear
        guard let target else { return true }
        guard let date else { return false }
        return Calendar.current.component(.year, from: date) == target
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Finished Books Yet", systemImage: "books.vertical")
        } description: {
            Text("Mark a book finished, log past reads, or import your history — and it shows up here.")
        } actions: {
            Button("Log a Book Read Elsewhere", systemImage: "plus") { showLogPast = true }.buttonStyle(.borderedProminent)
            Button("Import Reading History…", systemImage: "square.and.arrow.down") { importing = true }
        }
    }

    private var goalEditor: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Books per year: \(settings.yearlyBookGoal)", value: Binding(
                        get: { settings.yearlyBookGoal }, set: { settings.yearlyBookGoal = max(0, $0) }), in: 0...200)
                } footer: {
                    Text("Your target for the year's goal card. Set to 0 for no goal.")
                }
            }
            .navigationTitle("Yearly Goal").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGoalEditor = false } } }
        }
        .presentationDetents([.height(220)])
    }

    private func handleImport(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { importResult = "Couldn't read that file."; return }
        let (matched, logged) = library.importReadingHistory(data)
        importResult = matched + logged == 0
            ? "Nothing new to import — everything was already recorded."
            : "Imported \(matched + logged) books: \(matched) matched to your library, \(logged) logged as past reads."
    }
}

/// Read-only star row.
struct StarsView: View {
    let rating: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star").foregroundStyle(i <= rating ? .yellow : .secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating) out of 5 stars")
    }
}

/// Tappable star rating.
struct StarRatingPicker: View {
    @Binding var rating: Int?
    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: (rating ?? 0) >= i ? "star.fill" : "star")
                    .font(.title3).foregroundStyle((rating ?? 0) >= i ? .yellow : .secondary)
                    .onTapGesture { withAnimation(.snappy) { rating = (rating == i) ? nil : i } }
            }
            if rating != nil {
                Button("Clear") { rating = nil }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
}
