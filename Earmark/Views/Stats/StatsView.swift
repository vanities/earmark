import SwiftUI
import Charts
import UniformTypeIdentifiers

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
                    VStack(spacing: 22) {
                        goalRing(stats)
                        chips(stats)
                        if stats.years.count > 1 { yearFilter(stats) }
                        yearChart(stats)
                        if let dist = ratingDistribution(stats), dist.contains(where: { $0.count > 0 }) {
                            ratingsCard(dist, avg: stats.averageRating)
                        }
                        if !filteredAuthors(stats).isEmpty { authorsCard(stats) }
                        if !library.readingLog.isEmpty { loggedCard }
                    }
                    .padding()
                }
            }
            .navigationTitle("Stats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Log a Past Book", systemImage: "plus") { showLogPast = true }
                        Button("Import Reading History…", systemImage: "square.and.arrow.down") { importing = true }
                        if !library.readingLog.isEmpty || settings.yearlyBookGoal > 0 {
                            Button("Set Yearly Goal…", systemImage: "target") { showGoalEditor = true }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
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

    // MARK: Goal ring (Goal Gradient + Endowed Progress + Fresh Start)

    private func goalRing(_ stats: ReadingStats) -> some View {
        let goal = max(0, settings.yearlyBookGoal)
        let done = stats.thisYear
        let fraction = goal > 0 ? min(1, Double(done) / Double(goal)) : (done > 0 ? 1 : 0)
        return VStack(spacing: 10) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: animate ? fraction : 0)
                    .stroke(AngularGradient(colors: [.orange, .yellow, .orange], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(done)").font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(goal > 0 ? "of \(goal) this year" : "read this year").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)
            .onTapGesture { showGoalEditor = true }
            if goal > 0 {
                Text(done >= goal ? "Goal reached — nice." : "\(goal - done) to go. You're \(Int(fraction * 100))% there.")
                    .font(.footnote).foregroundStyle(done >= goal ? .green : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Summary chips

    private func chips(_ stats: ReadingStats) -> some View {
        HStack(spacing: 12) {
            chip("\(stats.totalBooks)", "Books", "books.vertical.fill")
            chip("\(Int(stats.totalHours.rounded()))", "Hours", "clock.fill")
            if let avg = stats.averageRating { chip(String(format: "%.1f", avg), "Avg Rating", "star.fill") }
            if let best = stats.bestYear { chip("\(best.count)", "Best (\(String(best.year)))", "trophy.fill") }
        }
    }

    private func chip(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(.tint)
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Year filter chips

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
        Button(action: { withAnimation(.snappy) { tap() } }) {
            Text(label).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Books-per-year bar chart (Von Restorff highlight, animated)

    private func yearChart(_ stats: ReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Books per Year").font(.headline)
            Chart(stats.years.sorted { $0.year < $1.year }) { year in
                BarMark(
                    x: .value("Year", String(year.year)),
                    y: .value("Books", animate ? year.count : 0)
                )
                .foregroundStyle(barColor(year))
                .cornerRadius(6)
                .annotation(position: .top) {
                    Text("\(year.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 190)
            .animation(.easeOut(duration: 0.7), value: animate)
        }
        .padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private func barColor(_ year: ReadingStats.Year) -> AnyShapeStyle {
        if let sel = selectedYear { return year.year == sel ? AnyShapeStyle(.orange) : AnyShapeStyle(.orange.opacity(0.25)) }
        if year.year == library.readingStats.bestYear?.year { return AnyShapeStyle(LinearGradient(colors: [.orange, .yellow], startPoint: .bottom, endPoint: .top)) }
        return AnyShapeStyle(.orange.opacity(0.6))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ratings").font(.headline)
                Spacer()
                if let avg { Text(String(format: "%.1f ★ avg", avg)).font(.subheadline).foregroundStyle(.secondary) }
            }
            let maxC = max(1, dist.map(\.count).max() ?? 1)
            ForEach(dist.reversed()) { b in
                HStack(spacing: 8) {
                    HStack(spacing: 1) {
                        ForEach(0..<b.stars, id: \.self) { _ in Image(systemName: "star.fill") }
                    }.font(.caption2).foregroundStyle(.yellow).frame(width: 66, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(.yellow.opacity(0.8))
                            .frame(width: max(b.count == 0 ? 0 : 8, geo.size.width * CGFloat(animate ? b.count : 0) / CGFloat(maxC)))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }.frame(height: 14)
                    Text("\(b.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                }
            }
        }
        .padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
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
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedYear.map { "Most Read in \($0)" } ?? "Most Read Authors").font(.headline)
            ForEach(filteredAuthors(stats).prefix(5)) { a in
                HStack {
                    Text(a.author).lineLimit(1)
                    Spacer()
                    Text("\(a.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Logged past books

    private var loggedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Logged Past Books").font(.headline).padding(.bottom, 2)
            ForEach(library.readingLog.sorted { $0.finishedAt > $1.finishedAt }) { entry in
                Button { editingEntry = entry } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).foregroundStyle(.primary).lineLimit(1)
                            HStack(spacing: 6) {
                                if let a = entry.author { Text(a).lineLimit(1) }
                                Text(entry.finishedAt, format: .dateTime.year())
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let r = entry.rating { StarsView(rating: r).font(.caption2) }
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
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
            Button("Log a Past Book", systemImage: "plus") { showLogPast = true }.buttonStyle(.borderedProminent)
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
                    Text("Your target for the ring at the top. Set to 0 to hide the goal.")
                }
            }
            .navigationTitle("Yearly Goal").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGoalEditor = false } } }
        }
        .presentationDetents([.height(220)])
    }

    private func handleImport(_ result: Result<URL, Error>) {
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
