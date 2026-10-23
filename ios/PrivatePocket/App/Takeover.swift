import SwiftUI

/// While it records, the whole screen: amber, breathing with the room's loudness, the
/// timer large, the waveform as it streams, the words as they come, a quiet thread named
/// in the room, what the reader has caught with a tick and a cross, what was said to the
/// card, and Stop. It rises out of the Dynamic Island when a recording starts, from the
/// app or the card's button, and again when the app is opened during one. Hide gives the
/// app back; the live block on Now brings it again. At the stop it says Saved and goes.
struct RecordingTakeover: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @EnvironmentObject var devices: DeviceStore
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = 76.0
    @ScaledMetric(relativeTo: .largeTitle) private var markSize = 64.0
    let hide: () -> Void

    private var recording: Bool { link.status.recordingSince != nil }
    private var ink: Color { Brand.onRecord }
    private var cream: Color { Color(hex: 0xFFF7E8) }

    /// The waveform's band: edge to edge, on the middle of the screen.
    private let band: CGFloat = 150

    var body: some View {
        ZStack {
            Brand.record.ignoresSafeArea()
            Breath(levels: live.levels, active: recording && live.isActive).ignoresSafeArea()
            if recording {
                GeometryReader { g in
                    let w = g.size.width
                    let top = g.safeAreaInsets.top
                    // The middle of the whole screen, in this view's own coordinates (it starts under the status bar).
                    let mid = (g.size.height + top + g.safeAreaInsets.bottom) / 2 - top
                    let upper = max(0, mid - band / 2 - 12)
                    let lowerTop = mid + band / 2 + 12
                    let lower = max(0, g.size.height - lowerTop)
                    wave
                        .frame(width: w, height: band)
                        .position(x: w / 2, y: mid)
                    VStack(spacing: 10) {
                        topBar
                        Spacer(minLength: 0)
                        hero
                    }
                    .frame(width: w, height: upper, alignment: .top)
                    .position(x: w / 2, y: upper / 2)
                    VStack(spacing: 0) {
                        ScrollView {
                            room.padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
                        }
                        .scrollIndicators(.hidden)
                        stop
                    }
                    .frame(width: w, height: lower, alignment: .top)
                    .position(x: w / 2, y: lowerTop + lower / 2)
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    saved
                    Spacer()
                }
            }
        }
        .foregroundStyle(ink)
        .task(id: recording) {
            // After the stop: Saving… while the stream is put away, Saved for a moment, then gone.
            guard !recording else { return }
            var waited = 0.0
            while !model.saving.isEmpty, waited < 8 {
                try? await Task.sleep(for: .milliseconds(300))
                waited += 0.3
            }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled, !recording { hide() }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Button(action: hide) {
                Image(systemName: "chevron.down").font(.headline.weight(.bold))
                    .frame(width: 44, height: 44)
                    .background(ink.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide, and keep recording")
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(ink).frame(width: 9, height: 9)
                Text(recording ? (model.recordingContext?.label ?? "Recording") : "Stopped")
                    .font(.subheadline.weight(.heavy)).tracking(0.6).textCase(.uppercase).lineLimit(1)
            }
            Spacer()
            PocketIllustration(fill: PocketLook(advertised: devices.selected?.advertisedName ?? "").fill,
                               light: recording ? Lamp.recording : Lamp.ready, pulse: recording)
                .frame(height: 44)
                .frame(width: 44)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    /// The timer, large, and what the stream is doing: above the waveform.
    private var hero: some View {
        VStack(spacing: 6) {
            if let since = link.status.recordingSince {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.system(size: timerSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
            Text(status).font(.footnote.weight(.bold)).opacity(0.75).multilineTextAlignment(.center).padding(.horizontal, 30)
        }
        .padding(.bottom, 4)
    }

    /// The waveform, from one edge of the screen to the other; faint dots while nothing streams.
    @ViewBuilder private var wave: some View {
        if live.isActive {
            LiveWave(levels: live.levels, ink: ink, bar: 4, gap: 3)
                .accessibilityLabel("Streaming to this iPhone")
        } else {
            LevelBars(levels: [], ink: ink, bar: 4, gap: 3).opacity(0.5)
        }
    }

    private var status: String {
        if !live.isActive { return "Recording on the card. It's fetched when it stops." }
        if live.gap { return "The stream was interrupted. The Pocket keeps recording." }
        return "Streaming to this iPhone"
    }

    /// The words, the recall, the catches, the card's answers.
    @ViewBuilder private var room: some View {
        VStack(alignment: .leading, spacing: 16) {
            let text = live.text
            if !text.isEmpty {
                Text(String(text.suffix(420)))
                    .font(.title3.weight(.semibold)).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.25), value: text.count)
            } else if live.isActive {
                Text("Listening…").font(.title3.weight(.semibold)).opacity(0.8)
            }
            if let h = model.liveThread { ThreadHintBox(hint: h, large: true) }
            if !model.liveItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.liveItems) { item in
                        let confirmed = model.liveConfirmed.contains(item.id), gone = model.liveDismissed.contains(item.id)
                        HStack(spacing: 12) {
                            Text(item.isAction ? "TO DO" : item.isDate ? "DATE" : "PROMISE").font(.caption.weight(.bold)).tracking(0.8)
                                .foregroundStyle(Brand.record).frame(width: 66, alignment: .leading)
                            Text((item.isPromise ? (item.who.map { "\($0): " } ?? "") : "") + item.text)
                                .font(.callout.weight(.bold)).foregroundStyle(cream).frame(maxWidth: .infinity, alignment: .leading)
                            Button { model.confirmLive(item) } label: {
                                Image(systemName: "checkmark").font(.callout.weight(.bold)).frame(width: 40, height: 40)
                                    .background(confirmed ? Brand.act : Color(hex: 0x4A3410), in: Circle())
                                    .foregroundStyle(confirmed ? Brand.onAct : cream)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Keep it")
                            Button { model.dismissLive(item) } label: {
                                Image(systemName: "xmark").font(.callout.weight(.bold)).frame(width: 40, height: 40)
                                    .background(Color(hex: 0x4A3410), in: Circle()).foregroundStyle(cream)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Drop it")
                        }
                        .padding(12)
                        .background(ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .opacity(gone ? 0.45 : 1)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.4), value: model.liveItems.count)
            }
            ForEach(model.liveDecisions.prefix(4), id: \.self) { d in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("DECIDED").font(.caption.weight(.bold)).tracking(0.8).frame(width: 66, alignment: .leading).opacity(0.7)
                    Text(d).font(.callout.weight(.bold))
                }
            }
            if let a = model.cardAnswers.last {
                VStack(alignment: .leading, spacing: 4) {
                    Text("“Pocket, \(a.question)”").font(.subheadline.weight(.semibold)).opacity(0.75)
                    Text(a.answer).font(.title3.weight(.bold))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var stop: some View {
        VStack(spacing: 8) {
            if model.canCommand {
                Button { Task { await model.toggleRecording() } } label: {
                    ZStack {
                        Circle().strokeBorder(ink, lineWidth: 4).frame(width: 84, height: 84)
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ink).frame(width: 32, height: 32)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
                Text("Stop").font(.footnote.weight(.bold))
            } else {
                Text("Press the side button on your Pocket to stop.").font(.footnote.weight(.bold))
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var saved: some View {
        VStack(spacing: 14) {
            let busy = !model.saving.isEmpty
            Image(systemName: busy ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: markSize, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: busy)
            Text(busy ? "Saving…" : "Saved").font(.largeTitle.weight(.bold))
            Text("On this iPhone. It's read in a moment.").font(.subheadline.weight(.semibold)).opacity(0.75)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A glow behind the timer that swells with the loudness of the room.
struct Breath: View {
    @ObservedObject var levels: LiveLevels
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let level = active ? CGFloat(max(0, levels.values.last ?? 0)) : 0
        let swell = reduceMotion ? 0.25 : level
        RadialGradient(colors: [Color.white.opacity(0.30 + 0.25 * swell), .clear],
                       center: UnitPoint(x: 0.5, y: 0.5), startRadius: 0, endRadius: 150 + 230 * swell)
            .animation(.easeOut(duration: 0.18), value: level)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The takeover rising out of the Dynamic Island: a circle from the top centre that opens
/// to the whole screen, and closes back into it.
struct IslandReveal: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { g in
                let reach = hypot(g.size.width, g.size.height) * 1.15
                Circle()
                    .frame(width: max(1, reach * 2 * progress), height: max(1, reach * 2 * progress))
                    .position(x: g.size.width / 2, y: 20)
            }
            .ignoresSafeArea()
        }
    }
}

extension AnyTransition {
    static var islandReveal: AnyTransition {
        .modifier(active: IslandReveal(progress: 0), identity: IslandReveal(progress: 1))
    }
}

/// Start a recording on the Pocket from the phone: an amber shutter. Faint when the Pocket
/// is out of reach or not paired; while it records it brings the takeover back. On a
/// thread, a person or a moment it records into it (`AppModel.pageContext`).
struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var devices: DeviceStore
    var size: CGFloat = 46

    var body: some View {
        let connected = link.connectedDeviceID != nil && link.connectedDeviceID == devices.selectedID
        let recording = link.status.recordingSince != nil
        let usable = model.canCommand && (connected || recording)
        Button {
            if recording { withAnimation(.spring(duration: 0.6)) { model.takeover = true } }
            else { Task { await model.toggleRecording() } }
        } label: {
            ZStack {
                Circle().fill(Brand.record).frame(width: size, height: size)
                if recording {
                    RoundedRectangle(cornerRadius: size * 0.08, style: .continuous).fill(Brand.onRecord).frame(width: size * 0.32, height: size * 0.32)
                } else {
                    Circle().fill(Brand.onRecord).frame(width: size * 0.36, height: size * 0.36)
                }
            }
            .shadow(color: Brand.record.opacity(usable ? 0.45 : 0), radius: size * 0.22, y: size * 0.08)
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(usable ? 1 : 0.35)
        .accessibilityLabel(recording ? "Show the recording" : model.pageContext.map { "Record, \($0.label.lowercased())" } ?? "Record")
    }
}

/// The Pocket in a word: its light and its state, opening its own screen.
struct PocketPill: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @EnvironmentObject var devices: DeviceStore
    let open: () -> Void

    private var connected: Bool { link.connectedDeviceID != nil && link.connectedDeviceID == devices.selectedID }
    private var recording: Bool { link.status.recordingSince != nil }

    private var state: String {
        if recording { return live.isActive ? "Recording" : "On the card" }
        if !model.canCommand { return "Needs pairing" }
        if !connected { return "Away" }
        if let c = model.pageContext { return c.label }
        if let b = link.status.battery { return "Ready · \(b)%" }
        return "Ready"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                LightDot(state: recording ? .recording : model.canCommand && connected ? .on : .off).frame(width: 8, height: 8)
                Text(state).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Brand.surface, in: Capsule())
            .foregroundStyle(Brand.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your Pocket: \(state)")
    }
}
