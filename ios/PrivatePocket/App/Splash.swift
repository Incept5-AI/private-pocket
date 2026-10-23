import SwiftUI

/// On start, a short scene: the house lights go down, the Pocket waits in the dark at the
/// centre of the screen, and a low raking light crosses it slowly. The light lifts the
/// darkness only where it falls, catches the card's edge, throws a long soft shadow the
/// other way, and the card's own light blooms on as the sweep passes it, with a slow push
/// in on the card. Then the name, and the app. A tap skips it; with Reduce Motion it is
/// the card, lit, for a moment.
struct SplashView: View {
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene = SplashScene.State()
    @State private var finished = false

    var body: some View {
        SplashScene(state: scene)
            .contentShape(Rectangle())
            .onTapGesture { finish() }
            .accessibilityHidden(true)
            .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            scene = .init(light: 0, dim: true, shown: true, push: true, lit: true, bloom: true, named: true)
            try? await Task.sleep(for: .seconds(1.0))
            finish()
            return
        }
        withAnimation(.easeInOut(duration: 0.55)) { scene.dim = true }
        withAnimation(.easeOut(duration: 0.8).delay(0.15)) { scene.shown = true }
        withAnimation(.easeOut(duration: 2.6)) { scene.push = true }
        withAnimation(.easeInOut(duration: 1.8).delay(0.3)) { scene.light = 1.6 }
        try? await Task.sleep(for: .seconds(0.95))   // the sweep reaches the card's light, top left
        scene.lit = true
        withAnimation(.easeOut(duration: 1.1)) { scene.bloom = true }
        try? await Task.sleep(for: .seconds(0.4))
        withAnimation(.easeOut(duration: 0.8)) { scene.named = true }
        try? await Task.sleep(for: .seconds(1.05))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        done()
    }
}

/// The scene at one instant, so it can be played by `SplashView` or drawn still.
struct SplashScene: View {
    struct State {
        /// Where the light is across the card: −1 is its left edge, 1 its right.
        var light: CGFloat = -1.6
        var dim = false
        var shown = false
        var push = false
        var lit = false
        var bloom = false
        var named = false
    }

    let state: State

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let cardH = min(h * 0.38, 340)
            let cardW = cardH * 230 / 366
            ZStack {
                Brand.ground
                Color.black.opacity(state.dim ? 0.74 : 0)
                // The beam: a broad, faint band of light crossing the frame with the sweep.
                LinearGradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.035), location: 0.5),
                    .init(color: .white.opacity(0), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                .frame(width: w * 0.9, height: h * 1.6)
                .rotationEffect(.degrees(18))
                .offset(x: state.light * cardW * 1.1)
                .blendMode(.plusLighter)
                // The light pooling on the ground under the card, moving with the sweep.
                Ellipse()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: cardW * 2.2, height: cardW * 1.1)
                    .blur(radius: cardW * 0.35)
                    .offset(x: state.light * cardW * 0.8, y: cardH * 0.42)
                CinemaCard(light: state.light, lit: state.lit, bloom: state.bloom)
                    .frame(width: cardW, height: cardH)
                    .scaleEffect(state.push ? 1 : 0.965)
                    .opacity(state.shown ? 1 : 0)
                Text("PRIVATE POCKET")
                    .font(.footnote.weight(.semibold))
                    .tracking(4)
                    .foregroundStyle(Brand.textSecondary.opacity(0.75))
                    .opacity(state.named ? 1 : 0)
                    .offset(y: cardH / 2 + 46 + (state.named ? 0 : 6))
                // The vignette: the frame's edges fall away to black.
                RadialGradient(colors: [.clear, .black.opacity(0.7)], center: .center,
                               startRadius: min(w, h) * 0.22, endRadius: max(w, h) * 0.72)
                    .allowsHitTesting(false)
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
    }
}

/// The card under a low raking light: darkness lifted only where the light falls, a soft
/// gloss at its heart, the edge catching it, a long shadow thrown the other way, and the
/// card's light blooming as it comes on.
struct CinemaCard: View {
    let light: CGFloat
    let lit: Bool
    let bloom: Bool

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let shape = RoundedRectangle(cornerRadius: w * 0.095, style: .continuous)
            ZStack {
                shape
                    .fill(Color.black.opacity(0.8))
                    .frame(width: w, height: h)
                    .blur(radius: w * 0.12)
                    .scaleEffect(x: 1 + abs(light) * 0.06, y: 1)
                    .offset(x: -light * w * 0.32, y: w * 0.2)
                PocketIllustration(light: lit ? Lamp.ready : nil, castsShadow: false)
                    .frame(width: w, height: h)
                // Darkness over the whole card, its button and switch too, lifted where the light falls.
                band(w: w, h: h, width: w * 6, stops: [
                    .init(color: .black.opacity(0.8), location: 0),
                    .init(color: .black.opacity(0.8), location: 0.44),
                    .init(color: .black.opacity(0.1), location: 0.5),
                    .init(color: .black.opacity(0.8), location: 0.56),
                    .init(color: .black.opacity(0.8), location: 1),
                ])
                .mask(PocketIllustration(castsShadow: false).frame(width: w, height: h))
                band(w: w, h: h, width: w * 0.9, stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0), location: 0.4),
                    .init(color: .white.opacity(0.11), location: 0.5),
                    .init(color: .white.opacity(0), location: 0.6),
                    .init(color: .white.opacity(0), location: 1),
                ])
                .mask(shape)
                .blendMode(.plusLighter)
                band(w: w, h: h, width: w * 0.6, stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.75), location: 0.5),
                    .init(color: .white.opacity(0), location: 1),
                ])
                .mask(shape.strokeBorder(lineWidth: 1.4))
                .blendMode(.plusLighter)
                // The card's light is a light: it glows above the darkness once it is on.
                if lit {
                    Circle()
                        .fill(Lamp.ready)
                        .frame(width: w * 0.04, height: w * 0.04)
                        .shadow(color: Lamp.ready.opacity(0.95), radius: w * 0.025)
                        .shadow(color: Lamp.ready.opacity(0.5), radius: w * 0.08)
                        .position(x: w * 0.116, y: w * 0.116)
                }
                Circle()
                    .fill(Lamp.ready)
                    .frame(width: w * 0.9, height: w * 0.9)
                    .scaleEffect(bloom ? 1 : 0.05)
                    .opacity(bloom ? 0 : (lit ? 0.6 : 0))
                    .blur(radius: w * 0.06)
                    .position(x: w * 0.116, y: w * 0.116)
                    .allowsHitTesting(false)
            }
            .frame(width: w, height: h)
        }
    }

    /// A diagonal band of light or dark, travelling across the card with the light.
    private func band(w: CGFloat, h: CGFloat, width: CGFloat, stops: [Gradient.Stop]) -> some View {
        ZStack {
            LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: width, height: h * 2.2)
                .rotationEffect(.degrees(18))
                .offset(x: light * w)
        }
        .frame(width: w, height: h)
        .allowsHitTesting(false)
    }
}
