import SwiftUI

/// Square cover art with a title-derived gradient placeholder. Loads thumbnails off-main.
struct ArtworkView: View {
    let artworkID: String?
    let title: String
    var cornerRadius: CGFloat = 12
    /// `.fit` shows the whole cover at its real aspect (no cropping) — use it where the art is large
    /// (player, detail). `.fill` keeps square thumbnails tidy in grids.
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                if contentMode == .fit {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { Image(uiImage: image).resizable().scaledToFill() }
                        .clipped()
                }
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit).overlay { PlaceholderCover(title: title) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: artworkID) {
            image = await ArtworkStore.shared.loadImage(for: artworkID)
        }
    }
}

struct PlaceholderCover: View {
    let title: String

    var body: some View {
        let (top, bottom) = Self.colors(for: title)
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 28, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(10)
        }
    }

    static func colors(for title: String) -> (Color, Color) {
        let hues: [Double] = [0.02, 0.07, 0.11, 0.33, 0.47, 0.55, 0.62, 0.71, 0.80, 0.92]
        var hash: UInt64 = 1469598103934665603
        for byte in title.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let hue = hues[Int(hash % UInt64(hues.count))]
        return (
            Color(hue: hue, saturation: 0.55, brightness: 0.62),
            Color(hue: hue + 0.04, saturation: 0.7, brightness: 0.35)
        )
    }
}
