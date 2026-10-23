import SwiftUI

/// First use: seven screens, swipe only. The card does the talking, four words a
/// screen: wake it, pair (the page finds and adds the Pocket itself), record, the
/// switch, what the light means, and the way back when it won't pair, with the reset
/// acted out on the card. Shown once on first launch, and again from Settings or the
/// Pocket menu.
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
                RepairPage(start: finish).tag(6)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            Button("Skip") { finish() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.muted)
                .padding(.horizontal, 22).padding(.top, 14)
                .opacity(page == last ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: page)
            Button("Next") { withAnimation { page = min(last, page + 1) } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.act)
                .padding(.horizontal, 22).padding(.bottom, 46)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
                        .font(.title.weight(.bold))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudge = false

    var body: some View {
        WalkPage(glow: Lamp.ready, headline: "Press once.\nHear everything.", line: "On your iPhone, or your own server. No account, no cloud.") {
            PocketIllustration(light: Lamp.ready)
        } footer: {
            HStack(spacing: 6) {
                Text("Swipe").font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).offset(x: nudge ? 5 : 0)
            }
            .foregroundStyle(Brand.act)
            .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { nudge = true } } }
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
    var colour: Color = Lamp.ready
    @State private var progress = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 44, height: 44)
            .onAppear { withAnimation(.linear(duration: seconds)) { progress = 1 } }
    }
}

/// Pairing, done from here. With no Pocket added yet, the page looks for one while the
/// user holds the button, adds the one it finds, connects, and the link pairs by itself
/// while the light blinks. With a Pocket already added, it shows that one's state.
struct PairPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var link: PocketLink
    @State private var waited = false

    private var added: Bool { !devices.devices.isEmpty }
    private var found: [Discovered] { link.discovered.sorted { $0.rssi > $1.rssi } }

    private var headline: String {
        if model.canCommand { return "Paired. Solid blue." }
        if added { return "Pairing. Keep it close…" }
        return found.isEmpty ? "Hold the side button." : found.count == 1 ? "Found it." : "Which one is yours?"
    }

    private var line: String {
        if model.canCommand { return "Pocket and your iPhone know each other now. Nothing to type, ever." }
        if added {
            return waited ? "The app does it by itself while it is open. If the light has stopped blinking, hold the side button again for five seconds."
                          : "The app does it by itself while it is open."
        }
        if found.isEmpty { return "Five seconds, until the light blinks blue. Your iPhone finds it from here." }
        return found.count == 1 ? "Adding \(found[0].name)…" : "More than one Pocket is nearby. Tap yours."
    }

    var body: some View {
        let done = model.canCommand
        WalkPage(glow: Lamp.ready, headline: headline, line: line) {
            PocketIllustration(light: Lamp.ready, blink: !done)
        } footer: {
            if !added, found.count > 1 {
                VStack(spacing: 8) {
                    ForEach(found) { d in
                        Button { add(d) } label: {
                            Text(d.name).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.horizontal, 48)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: done)
        .onAppear { if !added { link.disconnect(); link.startDiscovery() } }
        .onDisappear { if link.isDiscovering { link.stopDiscovery() } }
        .onChange(of: link.discovered) { if !added, found.count == 1, let d = found.first { add(d) } }
        .task {
            guard await hold(12) else { return }
            withAnimation { waited = true }
        }
    }

    /// Adds the Pocket and connects at once; the keyless handshake then pairs while it blinks.
    private func add(_ d: Discovered) {
        guard !devices.devices.contains(where: { $0.advertisedName == d.name }) else { return }
        let c = DeviceConfig(name: DeviceStore.defaultName(d.name), advertisedName: d.name, peripheralID: d.id)
        devices.add(c)
        link.stopDiscovery()
        Task { await model.userConnect() }
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

/// Where a reset is: tapping (two quick presses), holding (the third press kept down),
/// erasing (blinking red), ready (blinking blue, ready to pair).
enum ResetPhase { case tapping, holding, erasing, ready }

/// The card going through a reset, so the sequence reads as one thing: each quick press
/// counted beside the button, the third kept down while a red ring fills, then the light
/// blinking red as it erases, then blue.
struct ResetCard: View {
    let phase: ResetPhase
    let presses: Int
    let pressed: Bool

    private var light: Color? { phase == .erasing ? Lamp.resetting : Lamp.ready }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PocketIllustration(light: light, blink: phase == .erasing || phase == .ready, buttonPressed: pressed)
            if phase == .tapping, presses > 0 {
                Text("\(presses)")
                    .font(.headline.weight(.heavy))
                    .frame(width: 38, height: 38)
                    .background(Lamp.resetting, in: Circle())
                    .foregroundStyle(.white)
                    .offset(x: 36, y: 44)
                    .id(presses)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
            if phase == .holding {
                HoldRing(seconds: 2.4, colour: Lamp.resetting).offset(x: 34, y: 46)
            }
        }
    }
}

/// Plays the reset on a card: two taps, the third press held, red, then blue if `ready` is asked for.
@MainActor
private func playReset(phase: Binding<ResetPhase>, presses: Binding<Int>, pressed: Binding<Bool>, thenReady: Bool) async -> Bool {
    withAnimation { phase.wrappedValue = .tapping; presses.wrappedValue = 0; pressed.wrappedValue = false }
    guard await hold(0.9) else { return false }
    for n in 1...3 {
        withAnimation(.spring(duration: 0.25)) { pressed.wrappedValue = true; presses.wrappedValue = n }
        guard await hold(0.2) else { return false }
        if n < 3 {   // the third press stays down: that is the hold
            withAnimation(.easeOut(duration: 0.1)) { pressed.wrappedValue = false }
            guard await hold(0.34) else { return false }
        }
    }
    withAnimation { phase.wrappedValue = .holding }
    guard await hold(2.4) else { return false }
    withAnimation { phase.wrappedValue = .erasing; pressed.wrappedValue = false }
    guard await hold(2.8) else { return false }
    if thenReady {
        withAnimation { phase.wrappedValue = .ready }
        guard await hold(2.6) else { return false }
    }
    return true
}

/// The way back when it won't pair or keeps dropping out: Bluetooth off on the phone,
/// the card reset, Bluetooth on, pair again. Spelled out, because it is the one thing
/// the card cannot show you with its light.
struct RepairPage: View {
    let start: () -> Void
    @State private var step = 0   // bluetooth off, reset, bluetooth on, blinking blue, paired
    @State private var phase: ResetPhase = .tapping
    @State private var presses = 0
    @State private var pressed = false

    private var light: Color? { [nil, Lamp.resetting, nil, Lamp.ready, Lamp.ready][step] }
    private var blink: Bool { step == 1 || step == 3 }

    var body: some View {
        WalkPage(glow: step >= 3 ? Lamp.ready : step == 1 && phase == .erasing ? Lamp.resetting : nil,
                 headline: "If it won't pair, or drops out.",
                 line: "") {
            ZStack(alignment: .bottom) {
                Group {
                    if step == 1 {
                        ResetCard(phase: phase, presses: presses, pressed: pressed)
                    } else {
                        PocketIllustration(light: light, blink: blink)
                    }
                }
                .scaleEffect(0.78).offset(y: -22)
                VStack(alignment: .leading, spacing: 9) {
                    RepairStep(n: 1, text: "Turn Bluetooth off on your iPhone, in Settings.", on: step == 0)
                    RepairStep(n: 2, text: "Reset the Pocket: three quick presses, the third held until the light blinks red. It erases the card.", on: step == 1, tint: Lamp.resetting)
                    RepairStep(n: 3, text: "Turn Bluetooth back on.", on: step == 2)
                    RepairStep(n: 4, text: "Hold the side button five seconds until it blinks blue, then tap Pair.", on: step == 3)
                }
                .padding(.horizontal, 28)
            }
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
                guard await hold(2.6) else { return }
                withAnimation { step = 1 }
                guard await playReset(phase: $phase, presses: $presses, pressed: $pressed, thenReady: false) else { return }
                for i in 2..<5 {
                    withAnimation { step = i }
                    guard await hold(i == 4 ? 2.2 : 2.6) else { return }
                }
            }
        }
    }
}

struct RepairStep: View {
    let n: Int
    let text: String
    let on: Bool
    var tint: Color = Brand.act

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold))
                .foregroundStyle(on ? Color.white : tint)
                .frame(width: 20, height: 20)
                .background(on ? tint : tint.opacity(0.18), in: Circle())
            Text(text).font(.subheadline).foregroundStyle(on ? Brand.text : Brand.textSecondary)
        }
        .animation(.easeInOut(duration: 0.3), value: on)
    }
}
