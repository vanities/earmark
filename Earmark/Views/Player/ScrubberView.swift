import SwiftUI

/// Chapter-relative scrubber: drag shows the target time, release seeks.
struct ScrubberView: View {
    @Environment(PlayerEngine.self) private var player
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        let duration = max(player.chapterDuration, 1)
        let shown = isDragging ? dragValue : min(player.chapterElapsed, duration)
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { shown },
                    set: { newValue in
                        dragValue = newValue
                        isDragging = true
                    }
                ),
                in: 0...duration
            ) { editing in
                if editing {
                    dragValue = shown
                    isDragging = true
                } else {
                    isDragging = false
                    player.seek(toChapterTime: dragValue)
                }
            }
            .disabled(player.isLoading)
            .accessibilityLabel("Chapter position")
            .accessibilityValue("\(shown.clockString), \(max(0, duration - shown).clockString) remaining")
            HStack {
                Text(shown.clockString)
                Spacer()
                Text("-" + max(0, duration - shown).clockString)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}
