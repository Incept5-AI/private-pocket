import SwiftUI

/// First use: seven screens, swipe only. The card does the talking, four words a
/// screen: wake it, pair, record, the switch, what the light means, and reset. Shown
/// once on first launch, and again from Settings or the Pocket menu.
struct WalkthroughView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    private let last = 6

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Brand.ground.ignoresSafeArea()
            TabView(selection: $page) {
                WelcomePage().tag(0)
                WakePage().tag(1)
                PairPage().tag(2)
                RecordPage().tag(3)
                SwitchPage().tag(4)
                LightPage().tag(5)
                ResetPage(start: finish).tag(6)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            Button("Skip") { finish() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.muted)
                .padding(.horizontal, 22).padding(.top, 14)
                .opacity(page == last ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: page)
        }
        .preferredColorScheme(.dark)
    }

    private func finish() {
        Prefs.walkthroughSeen = true
        dismiss()
    }
}

/// One screen: the atmosphere in the light's colour, the card large, a headline, a line.
struct WalkPage<Card: View, Footer: View>: View {
    let glow: Color?
    let headline: String
    let line: String
    let card: Card
    let footer: Footer

    init(glow: Color?, headline: String, line: String, @ViewBuilder card: () -> Card, @ViewBuilder footer: () -> Footer) {
        self.glow = glow
        self.headline = headline
        self.line = line
        self.card = card()
        self.footer = footer()
    }

    var body: some View {
        ZStack {
            RadialGradient(colors: [(glow ?? .clear).opacity(0.26), .clear],
                           center: UnitPoint(x: 0.5, y: 0.36), startRadius: 0, endRadius: 340)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.7), value: glow)
            VStack(spacing: 30) {
                Spacer(minLength: 0)
                card.frame(height: 310)
                VStack(spacing: 10) {
                    Text(headline)
                        .font(.system(size: 30, weight: .bold))
                        .multilineTextAlignment(.center)
                        .id(headline)
                        .transition(.opacity)
                    Text(line)
                        .font(.body)
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.center)
                        .id(line)
                        .transition(.opacity)
                }
                .padding(.horizontal, 30)
                .frame(minHeight: 130, alignment: .top)
                .animation(.easeInOut(duration: 0.35), value: headline)
                .animation(.easeInOut(duration: 0.35), value: line)
                footer
                Spacer(minLength: 0)
            }
            .padding(.bottom, 56)
        }
    }
}

extension WalkPage where Footer == EmptyView {
    init(glow: Color?, headline: String, line: String, @ViewBuilder card: () -> Card) {
        self.init(glow: glow, headline: headline, line: line, card: card, footer: { EmptyView() })
    }
}

/// Sleeps, and says whether the page is still on screen.
private func hold(_ seconds: Double) async -> Bool {
    try? await Task.sleep(for: .seconds(seconds))
    return !Task.isCancelled
}

// MARK: - The screens

struct WelcomePage: View {
    @State private var nudge = false

    var body: some View {
        WalkPage(glow: Lamp.ready, headline: "Press once.\nHear everything.", line: "On your iPhone only. No account, no cloud.") {
            PocketIllustration(light: Lamp.ready)
        } footer: {
            HStack(spacing: 6) {
                Text("Swipe").font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).offset(x: nudge ? 5 : 0)
            }
            .foregroundStyle(Brand.act)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { nudge = true } }
        }
    }
}

struct WakePage: View {
    @State private var step = 0   // asleep, holding, blinking

    var body: some View {
        WalkPage(glow: step == 2 ? Lamp.ready : nil,
                 headline: step == 2 ? "Blinking blue." : "Hold the side button.",
                 line: step == 2 ? "It's listening for your iPhone." : "Five seconds, until the light blinks blue.") {
            ZStack(alignment: .topTrailing) {
                PocketIllustration(light: step == 2 ? Lamp.ready : nil, blink: step == 2, buttonPressed: step == 1)
                if step == 1 { HoldRing(seconds: 2.6).offset(x: 34, y: 46) }
            }
        }
        .task {
            while !Task.isCancelled {
                withAnimation { step = 0 }
                guard await hold(1.2) else { return }
                withAnimation { step = 1 }
                guard await hold(2.6) else { return }
                withAnimation { step = 2 }
                guard await hold(3) else { return }
            }
        }
    }
}

/// A ring that fills over the hold, beside the button.
struct HoldRing: View {
    let seconds: Double
    @State private var progress = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(Lamp.ready, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 44, height: 44)
            .onAppear { withAnimation(.linear(duration: seconds)) { progress = 1 } }
    }
}

struct PairPage: View {
    @State private var paired = false

    var body: some View {
        WalkPage(glow: Lamp.ready,
                 headline: paired ? "Paired. Solid blue." : "Pairing. Keep it close…",
                 line: paired ? "Pocket and your iPhone know each other now. Nothing to type, ever." : "The app does it by itself.") {
            PocketIllustration(light: Lamp.ready, blink: !paired)
        }
        .task {
            while !Task.isCancelled {
                withAnimation { paired = false }
                guard await hold(2.6) else { return }
                withAnimation { paired = true }
                guard await hold(3.2) else { return }
            }
        }
    }
}

struct RecordPage: View {
    @State private var step = 0   // ready, recording, paused, recording, saved
    @State private var pressed = false

    private var light: Color { [Lamp.ready, Lamp.recording, Lamp.paused, Lamp.recording, Lamp.ready][step] }
    private var headline: String { ["Press to record.", "Recording.", "Paused.", "Recording.", "Saved."][step] }
    private var line: String {
        ["Once, like a camera.",
         "Amber. It streams to your iPhone as it goes.",
         "Press twice to pause. Twice again to carry on.",
         "Carrying on.",
         "Press once more to stop. It's on your iPhone."][step]
    }

    var body: some View {
        WalkPage(glow: light, headline: headline, line: line) {
            PocketIllustration(light: light, pulse: step == 1 || step == 3, buttonPressed: pressed)
        }
        .task {
            while !Task.isCancelled {
                for s in 0..<5 {
                    withAnimation { step = s }
                    guard await hold(s == 0 || s == 4 ? 1.8 : 2.4) else { return }
                    let presses = (s == 1 || s == 2) ? 2 : (s == 4 ? 0 : 1)
                    for _ in 0..<presses {
                        withAnimation { pressed = true }
                        guard await hold(0.16) else { return }
                        withAnimation { pressed = false }
                        guard await hold(0.22) else { return }
                    }
                }
            }
        }
    }
}

struct SwitchPage: View {
    @State private var down = false

    var body: some View {
        WalkPage(glow: Lamp.ready,
                 headline: down ? "Call." : "Audio.",
                 line: down ? "Down, on the back of your iPhone. It hears both sides." : "Up, for the room you're in.") {
            ZStack(alignment: .topTrailing) {
                PocketIllustration(light: Lamp.ready, switchDown: down)
                SwitchLoupe(down: down).frame(width: 128, height: 128).offset(x: 66, y: 58)
            }
            .offset(x: -30)
        }
        .task {
            while !Task.isCancelled {
                guard await hold(2.4) else { return }
                withAnimation(.spring(duration: 0.4)) { down.toggle() }
            }
        }
    }
}

/// The switch at three times its size, in a glass circle beside the card.
struct SwitchLoupe: View {
    let down: Bool

    var body: some View {
        ZStack {
            Circle().fill(Brand.surface)
                .overlay(Circle().strokeBorder(Brand.act.opacity(0.6), lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            VStack {
                Text("Audio").font(.caption2.weight(.semibold)).foregroundStyle(down ? Brand.muted : Brand.text)
                Spacer()
                Text("Call").font(.caption2.weight(.semibold)).foregroundStyle(down ? Brand.text : Brand.muted)
            }
            .padding(.vertical, 16)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.8)).frame(width: 18, height: 60)
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(white: 0.86)).frame(width: 12, height: 24)
                    .offset(y: down ? 33 : 3)
            }
        }
        .animation(.spring(duration: 0.4), value: down)
    }
}

struct LightPage: View {
    private struct Meaning {
        let light: Color?
        let blink: Bool
        let pulse: Bool
        let headline: String
        let line: String
    }

    private static let meanings: [Meaning] = [
        Meaning(light: Lamp.ready, blink: false, pulse: false, headline: "Solid blue.", line: "Ready."),
        Meaning(light: Lamp.recording, blink: false, pulse: true, headline: "Amber.", line: "Recording."),
        Meaning(light: Lamp.paused, blink: false, pulse: false, headline: "White.", line: "Paused."),
        Meaning(light: Lamp.charging, blink: true, pulse: false, headline: "Blinking green.", line: "Charging. Solid green when it's full."),
        Meaning(light: Lamp.updating, blink: true, pulse: false, headline: "Blinking purple.", line: "Updating. Leave it be."),
        Meaning(light: Lamp.resetting, blink: true, pulse: false, headline: "Blinking red.", line: "Resetting."),
        Meaning(light: nil, blink: false, pulse: false, headline: "No light.", line: "Asleep. Hold the button to wake it."),
    ]

    @State private var index = 0

    var body: some View {
        let m = Self.meanings[index]
        WalkPage(glow: m.light, headline: m.headline, line: m.line) {
            PocketIllustration(light: m.light, blink: m.blink, pulse: m.pulse)
        }
        .task {
            while !Task.isCancelled {
                guard await hold(2.1) else { return }
                withAnimation { index = (index + 1) % Self.meanings.count }
            }
        }
    }
}

struct ResetPage: View {
    let start: () -> Void
    @State private var step = 0   // press three times, hold, erasing, ready to pair
    @State private var pressed = false

    private var light: Color { step == 2 ? Lamp.resetting : Lamp.ready }
    private var headline: String { ["Press three times.", "Then hold.", "Erasing.", "Blinking blue again."][step] }
    private var line: String {
        ["Quickly, like a triple click.",
         "Keep it held until the light turns red.",
         "Blinking red. Everything on the card is gone.",
         "Ready to pair, like new."][step]
    }

    var body: some View {
        WalkPage(glow: light, headline: headline, line: line) {
            PocketIllustration(light: light, blink: step >= 2, buttonPressed: pressed)
        } footer: {
            Button { start() } label: {
                Text("Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.act)
            .padding(.horizontal, 64)
        }
        .task {
            while !Task.isCancelled {
                withAnimation { step = 0 }
                guard await hold(0.8) else { return }
                for _ in 0..<3 {
                    withAnimation { pressed = true }
                    guard await hold(0.14) else { return }
                    withAnimation { pressed = false }
                    guard await hold(0.2) else { return }
                }
                guard await hold(0.6) else { return }
                withAnimation { step = 1; pressed = true }
                guard await hold(2.2) else { return }
                withAnimation { step = 2; pressed = false }
                guard await hold(2.6) else { return }
                withAnimation { step = 3 }
                guard await hold(2.6) else { return }
            }
        }
    }
}
