import SwiftUI

// Shared by the app and the widget extension: loudness, drawn.

/// Loudness as bars centred on a line, newest at the right. The record bar draws it ten
/// times a second from the stream; the Dynamic Island and the Lock Screen draw it from the
/// levels the app sends every two seconds. Bars not heard yet are faint dots.
struct LevelBars: View {
    /// 0…1, oldest first; a negative value is a stretch with nothing arriving.
    let levels: [Float]
    var ink: Color
    var bar: CGFloat = 3
    var gap: CGFloat = 2
    /// A fixed number of bars, sized to fit; otherwise as many as fit at `bar` wide.
    var count: Int? = nil

    var body: some View {
        GeometryReader { g in
            let n = count ?? max(1, Int((g.size.width + gap) / (bar + gap)))
            let width = count == nil ? bar : max(1.5, (g.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let shown = Array(levels.suffix(n))
            let pad = n - shown.count
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<n, id: \.self) { i in
                    let v: Float = i < pad ? -1 : shown[i - pad]
                    Capsule()
                        .fill(ink.opacity(v < 0 ? 0.3 : 1))
                        .frame(width: width, height: max(width, CGFloat(max(v, 0)) * g.size.height))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }
}
