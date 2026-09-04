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
