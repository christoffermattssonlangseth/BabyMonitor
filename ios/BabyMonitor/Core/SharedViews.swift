import SwiftUI

/// Small rounded label with an optional status dot.
struct Pill: View {
    let text: String
    var color: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let color {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text)
        }
        .font(.footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }
}

/// Horizontal sound meter, 0–100, with an optional alert-threshold marker.
struct LevelMeter: View {
    let level: Int
    var threshold: Int?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                LinearGradient(colors: [.green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing)
                    .clipShape(Capsule())
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * CGFloat(level) / 100)
                    }
                if let threshold {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2)
                        .offset(x: geo.size.width * CGFloat(threshold) / 100 - 1)
                }
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.15), value: level)
        .accessibilityElement()
        .accessibilityLabel("Sound level")
        .accessibilityValue("\(level) percent")
    }
}
