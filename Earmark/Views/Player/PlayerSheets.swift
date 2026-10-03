import SwiftUI

struct SpeedSheet: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                speedControls
            }
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var speedControls: some View {
        VStack(spacing: 22) {
            Text(TransportControls.speedLabel(player.speed))
                .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy, value: player.speed)
            HStack(spacing: 14) {
                Button {
                    player.setSpeed(player.speed - 0.05)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                Slider(
                    value: Binding(get: { Double(player.speed) }, set: { player.setSpeed(Float($0)) }),
                    in: Double(AppSettings.speedRange.lowerBound)...Double(AppSettings.speedRange.upperBound),
                    step: 0.05
                )
                Button {
                    player.setSpeed(player.speed + 0.05)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                ForEach(AppSettings.speedPresets, id: \.self) { preset in
                    let selected = abs(preset - player.speed) < 0.01
                    Button {
                        player.setSpeed(preset)
                    } label: {
                        Text(TransportControls.speedLabel(preset))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Speech is time-stretched, so voices keep their natural pitch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

struct SleepTimerSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    private let options: [SleepTimerMode] = [
        .off, .duration(5 * 60), .duration(10 * 60), .duration(15 * 60), .duration(30 * 60), .duration(45 * 60), .duration(60 * 60), .endOfChapter,
    ]

    var body: some View {
        NavigationStack {
            List {
                if let remaining = player.sleepRemaining {
                    Section {
                        Label("Pausing in \(remaining.clockString)", systemImage: "moon.zzz.fill")
                            .monospacedDigit()
                        HStack(spacing: 12) {
                            ForEach([5, 15], id: \.self) { minutes in
                                Button {
                                    player.extendSleepTimer(by: TimeInterval(minutes * 60))
                                } label: {
                                    Text("+\(minutes) min").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .accessibilityLabel("Add \(minutes) minutes")
                            }
                        }
                    }
                } else if player.sleepTimer == .endOfChapter {
                    Section {
                        Label("Pausing at the end of this chapter", systemImage: "moon.zzz.fill")
                    }
                }
                Section {
                    Toggle("Save bedtime starting point", isOn: Bindable(settings).bedtimeBookmarks)
                    if let mark = player.bedtimeBookmark {
                        Button("Return to bedtime start · \(mark.offset.shortDurationString)", systemImage: "moon") {
                            player.seek(toBookOffset: mark.offset)
                            dismiss()
                        }
                    }
                } footer: {
                    Text("Saves one bookmark per book each night when you start a sleep timer. Find it later in Bookmarks.")
                }
                Section {
                    ForEach(options, id: \.self) { option in
                        Button {
                            player.setSleepTimer(option)
                            dismiss()
                        } label: {
                            HStack {
                                Text(option.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if player.sleepTimer == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
    }
}

struct ChapterListSheet: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let book = player.book {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                            let isCurrent = player.currentChapterIndex == index
                            Button {
                                player.jump(to: chapter)
                                if !player.isPlaying { player.play() }
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 28, alignment: .trailing)
                                    Text(chapter.title)
                                        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                                        .fontWeight(isCurrent ? .semibold : .regular)
                                        .lineLimit(2)
                                    Spacer()
                                    if isCurrent {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundStyle(.tint)
                                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                    }
                                    Text(chapter.duration.clockString)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .id(chapter.id)
                        }
                    }
                    .navigationTitle("Chapters")
                    .navigationBarTitleDisplayMode(.inline)
                    .onAppear {
                        if let current = player.currentChapter {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

struct BookmarksSheet: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Bookmark?
    @State private var noteDraft = ""

    var body: some View {
        NavigationStack {
            Group {
                if let book = player.book {
                    let marks = library.bookmarks(for: book)
                    if marks.isEmpty {
                        ContentUnavailableView("No Bookmarks", systemImage: "bookmark",
                            description: Text("Tap Add Bookmark while listening to save your spot."))
                    } else {
                        List {
                            ForEach(marks) { mark in
                                Button {
                                    player.seek(toBookOffset: mark.offset)
                                    dismiss()
                                } label: { row(for: mark, in: book) }
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        library.removeBookmark(mark.id, for: book)
                                    }
                                    Button("Note", systemImage: "square.and.pencil") {
                                        noteDraft = mark.note; editing = mark
                                    }.tint(.indigo)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Bookmark Note", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Note", text: $noteDraft)
                Button("Save") {
                    if let mark = editing, let book = player.book { library.updateBookmark(mark.id, for: book, note: noteDraft) }
                    editing = nil
                }
                Button("Cancel", role: .cancel) { editing = nil }
            }
        }
    }

    private func row(for mark: Bookmark, in book: Book) -> some View {
        let pos = book.position(atAbsoluteOffset: mark.offset)
        let chapter = book.chapter(at: pos.trackIndex, time: pos.time)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "bookmark.fill").foregroundStyle(.tint).font(.caption)
                Text(mark.offset.shortDurationString).font(.subheadline.weight(.medium)).monospacedDigit()
                Spacer()
                if book.chapters.count > 1, let chapter { Text(chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if !mark.note.isEmpty { Text(mark.note).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

struct ListeningQueueSheet: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Play queued books automatically", isOn: Bindable(settings).autoplayQueue)
                } footer: { Text("A sleep timer stops playback before another book starts.") }
                Section("Up next") {
                    if player.queueKeys.isEmpty { Text("Your queue is empty").foregroundStyle(.secondary) }
                    ForEach(player.queueKeys, id: \.self) { key in
                        if let book = player.queuedBook(for: key) {
                            Button { player.load(book, autoplay: true); dismiss() } label: {
                                VStack(alignment: .leading) {
                                    Text(book.title).foregroundStyle(.primary)
                                    Text(book.displayAuthor).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else { Label("Book unavailable · remove or reconnect its source", systemImage: "exclamationmark.triangle") }
                    }
                    .onDelete { player.removeQueued(at: $0) }
                    .onMove { player.moveQueued(from: $0, to: $1) }
                }
            }
            .navigationTitle("Listening queue")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .primaryAction) { Button("Add", systemImage: "plus") { adding = true } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $adding) {
                NavigationStack {
                    List(library.visibleBooks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { book in
                        Button { player.enqueue(book) } label: {
                            HStack {
                                Text(book.title)
                                Spacer()
                                if player.queueKeys.contains(book.syncKey) { Image(systemName: "checkmark") }
                            }
                        }.disabled(player.queueKeys.contains(book.syncKey) || player.book?.syncKey == book.syncKey)
                    }
                    .searchable(text: $search)
                    .navigationTitle("Add to queue")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { adding = false } } }
                }
            }
        }
    }
}
