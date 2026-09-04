import SwiftUI

struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4
    var trackColor: Color = Color(.tertiarySystemFill)
    var fillColor: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(height, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// Progress pill drawn over cover art.
struct CoverProgressBar: View {
    let fraction: Double

    var body: some View {
        ProgressBar(fraction: fraction, height: 5, trackColor: .white.opacity(0.35), fillColor: .white)
            .padding(6)
            .background(.black.opacity(0.35), in: Capsule())
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
            if let count {
                Text("\(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
