import WidgetKit
import SwiftUI
import UIKit

struct ContinueEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot?
    let cover: Image?
}

struct ContinueProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueEntry {
        ContinueEntry(date: .now, snapshot: NowPlayingSnapshot(bookID: "", title: "Your Audiobook",
            author: "Author", fraction: 0.4, remaining: "3h 12m left", isPlaying: false, updatedAt: .now), cover: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) {
        completion(load())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        // Static until the app writes a new snapshot and reloads us; refresh hourly as a safety net.
        completion(Timeline(entries: [load()], policy: .after(.now.addingTimeInterval(3600))))
    }
    private func load() -> ContinueEntry {
        let snap = SharedNowPlaying.read()
        var cover: Image?
        if let url = SharedNowPlaying.coverURL, let data = try? Data(contentsOf: url), let ui = UIImage(data: data) {
            cover = Image(uiImage: ui)
        }
        return ContinueEntry(date: .now, snapshot: snap, cover: cover)
    }
}

struct ContinueListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueListening", provider: ContinueProvider()) { entry in
            ContinueListeningView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Continue Listening")
        .description("Your current audiobook, one tap to resume.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ContinueListeningView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueEntry

    var body: some View {
        if let snap = entry.snapshot, !snap.title.isEmpty {
            Group {
                switch family {
                case .systemSmall: small(snap)
                default: medium(snap)
                }
            }
            .widgetURL(URL(string: "earmark://resume"))
        } else {
            empty
        }
    }

    private func cover(_ size: CGFloat) -> some View {
        Group {
            if let cover = entry.cover {
                cover.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack { Rectangle().fill(.quaternary); Image(systemName: "book.closed").font(.title2).foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func small(_ snap: NowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cover(56)
            Text(snap.title).font(.caption.bold()).lineLimit(2)
            Spacer(minLength: 0)
            ProgressView(value: snap.fraction).tint(.accentColor)
            HStack {
                Text(snap.remaining).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Image(systemName: snap.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(Color.accentColor)
            }
        }
    }

    private func medium(_ snap: NowPlayingSnapshot) -> some View {
        HStack(spacing: 14) {
            cover(108)   // as tall as Mango's medium cover (74 × 1.45)
            VStack(alignment: .leading, spacing: 6) {
                Text(snap.title).font(.headline).lineLimit(2)
                Text(snap.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                ProgressView(value: snap.fraction).tint(.accentColor)
                HStack(spacing: 6) {
                    Text(snap.remaining).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    // Never squeezed to "Resu…": a long time left gives way first.
                    Label(snap.isPlaying ? "Playing" : "Resume", systemImage: snap.isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.tint, in: Capsule()).foregroundStyle(.white)
                        .fixedSize()
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "headphones").font(.title).foregroundStyle(.secondary)
            Text("Nothing playing").font(.caption).foregroundStyle(.secondary)
            Text("Open Earmark to start a book.").font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding()
    }
}
