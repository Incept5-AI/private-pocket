import SwiftUI

/// On start: the Pocket on the dark ground with a light passing across it. The sheen runs
/// over the card, its shadow swings the other way, its light comes on as the sweep goes
/// by, and the name settles under it; then the app. A tap skips it. With Reduce Motion it
/// is the card, lit, for a moment.
struct SplashView: View {
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the light is across the card: −1 is its left edge, 1 its right.
    @State private var light: CGFloat = -1.4
    @State private var shown = false
    @State private var lit = false
    @State private var named = false
    @State private var finished = false

    var body: some View {
        GeometryReader { g in
            let cardH = min(g.size.height * 0.42, 360)
            let cardW = cardH * 230 / 366
            ZStack {
                Brand.ground.ignoresSafeArea()
                // The lamp: a soft pool of light on the ground that travels with the sweep.
                Circle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: cardW * 2.4, height: cardW * 2.4)
                    .blur(radius: cardW * 0.5)
                    .position(x: g.size.width / 2 + light * cardW * 0.9, y: g.size.height * 0.4)
                VStack(spacing: 38) {
                    LitCard(light: light, lit: lit)
                        .frame(width: cardW, height: cardH)
                        .scaleEffect(shown ? 1 : 0.94)
                        .opacity(shown ? 1 : 0)
                    Text("Private Pocket")
                        .font(.title2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(Brand.textSecondary)
                        .opacity(named ? 1 : 0)
                        .offset(y: named ? 0 : 8)
                }
                .position(x: g.size.width / 2, y: g.size.height * 0.47)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityHidden(true)
        .task { await play() }
    }

    private func play() async {
        withAnimation(.easeOut(duration: 0.35)) { shown = true }
        if reduceMotion {
            light = 0.3
            lit = true
            named = true
            try? await Task.sleep(for: .seconds(0.9))
            finish()
            return
        }
        withAnimation(.easeInOut(duration: 1.35).delay(0.1)) { light = 1.4 }
        try? await Task.sleep(for: .seconds(0.6))   // the sweep reaches the light, top left
        withAnimation(.easeOut(duration: 0.25)) { lit = true }
        try? await Task.sleep(for: .seconds(0.15))
        withAnimation(.easeOut(duration: 0.45)) { named = true }
        try? await Task.sleep(for: .seconds(0.95))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        done()
    }
}

/// The card under a moving light: a band of sheen crossing its face, and its shadow thrown
/// away from the light, so it swings across the ground as the light passes.
struct LitCard: View {
    let light: CGFloat
    let lit: Bool

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let radius = w * 0.095
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.opacity(0.62))
                    .frame(width: w, height: h)
                    .blur(radius: w * 0.09)
                    .offset(x: -light * w * 0.24, y: w * 0.16)
                PocketIllustration(light: lit ? Lamp.ready : nil, castsShadow: false)
                    .frame(width: w, height: h)
                ZStack {
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.10), location: 0.34),
                        .init(color: .white.opacity(0.42), location: 0.5),
                        .init(color: .white.opacity(0.10), location: 0.66),
                        .init(color: .white.opacity(0), location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.9, height: h * 1.7)
                    .rotationEffect(.degrees(18))
                    .offset(x: light * w)
                }
                .frame(width: w, height: h)
                .mask(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
            .frame(width: w, height: h)
        }
    }
}
