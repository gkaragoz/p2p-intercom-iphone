import SwiftUI

/// Horizontal level meter; `level` is 0...1. An optional `marker` (also 0...1) draws a threshold line.
struct LevelMeterView: View {
    var level: Float
    var marker: Float?
    var tint: Color = .green

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                LinearGradient(colors: [tint, .yellow, .red], startPoint: .leading, endPoint: .trailing)
                    .clipShape(Capsule())
                    .mask(alignment: .leading) {
                        Capsule().frame(width: max(0, width * CGFloat(min(1, max(0, level)))))
                    }
                if let marker {
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: width * CGFloat(min(1, max(0, marker))) - 1)
                }
            }
        }
        .frame(height: 12)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityHidden(true)
    }
}
