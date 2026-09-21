import SwiftUI

struct SpeedSheet: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(spacing: 22) {
            Text("Playback Speed")
                .font(.headline)
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
        .presentationDragIndicator(.visible)
    }
}

struct SleepTimerSheet: View {
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
