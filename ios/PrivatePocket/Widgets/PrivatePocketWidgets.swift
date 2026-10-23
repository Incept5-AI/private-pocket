import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PrivatePocketWidgets: WidgetBundle {
    var body: some Widget {
        PocketLiveActivity()
        PocketRecordingControl()
    }
}

// MARK: - Control Center

/// The side button, on the phone: one toggle in Control Center and on the Lock Screen.
/// Its state comes from the app through the shared Keychain (`SharedState`).
struct PocketRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.incept5.private-pocket.record", provider: RecordingStateProvider()) { recording in
            ControlWidgetToggle("Pocket", isOn: recording, action: ToggleRecordingIntent()) { on in
                Label(on ? "Recording" : "Record", systemImage: on ? "record.circle.fill" : "record.circle")
            }
            .tint(Brand.record)
        }
        .displayName("Pocket")
        .description("Starts or stops recording on your Pocket, like its side button.")
    }
}

struct RecordingStateProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { SharedState.recording }
}

/// The Pocket in the Dynamic Island and on the Lock Screen. While it records: a live
/// waveform of the last few seconds, the timer, what Record was pressed into, the words as
/// they come, what the reader has caught or a quiet thread named in the room, and Stop.
/// Saved: the length, then what the moment was. Connected and idle: the card with its
/// real light, the battery, and Record. Out of range: the card on its own.
struct PocketLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            let look = PocketLook(advertised: context.attributes.advertised)
            LockScreenView(context: context)
                .activityBackgroundTint(context.state.isRecording ? Brand.record : look.fill)
                .activitySystemActionForegroundColor(context.state.isRecording ? Brand.onRecord : look.ink)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandCard(state: s, advertised: context.attributes.advertised)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandFigure(state: s)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandHeadline(state: s, pocket: context.attributes.pocketName)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandBottom(state: s)
                }
            } compactLeading: {
                CompactLeading(state: s)
            } compactTrailing: {
                TrailingFigure(state: s)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(s.isRecording ? Brand.record : .white)
                    .frame(maxWidth: 54, alignment: .trailing)
            } minimal: {
                MinimalView(state: s)
            }
            .keylineTint(s.isRecording ? Brand.record : Lamp.ready)
        }
    }
}

extension RecordingAttributes.ContentState {
    /// The card's light as the card shows it.
    var lamp: Color? {
        switch phase {
        case .recording: Lamp.recording
        case .ready, .saved, .stopped: Lamp.ready
        case .waiting: nil
        }
    }

    /// The waveform has something to show.
    var hasWave: Bool { isRecording && streaming && !gap && !(levels ?? []).isEmpty }
}

/// The card itself, small, with its light: the left of the expanded island.
struct IslandCard: View {
    let state: RecordingAttributes.ContentState
    let advertised: String

    var body: some View {
        PocketIllustration(fill: PocketLook(advertised: advertised).fill, light: state.lamp)
            .frame(height: 50)
            .padding(.leading, 8)
            .padding(.top, 4)
    }
}

/// The phase in a word or two, and the line under it.
struct IslandHeadline: View {
    let state: RecordingAttributes.ContentState
    let pocket: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline).foregroundStyle(state.isRecording ? Brand.record : .white).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var title: String {
        switch state.phase {
        case .recording: "Recording"
        case .saved: state.read == nil ? "Saved" : "Read"
        case .ready: pocket
        case .waiting: "Out of range"
        case .stopped: "Stopped"
        }
    }

    private var subtitle: String {
        switch state.phase {
        case .recording:
            if let c = state.context { return c }
            if !state.streaming { return "On the card" }
            return state.gap ? "Stream interrupted" : "Streaming to this iPhone"
        case .saved:
            return state.savedSeconds.map { "On this iPhone · \(PocketFacts.length($0))" } ?? "On this iPhone"
        case .ready:
            return state.hoursFree.map { "Ready · \($0) free" } ?? "Ready"
        case .waiting:
            return "\(pocket) keeps recording on its own"
        case .stopped:
            return "Fetched when the phone connects"
        }
    }
}

/// The number that matters, large: the running time, the saved length, the battery.
struct IslandFigure: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        TrailingFigure(state: state)
            .font(.title2.monospacedDigit().weight(.bold))
            .foregroundStyle(state.isRecording ? Brand.record : .white)
            .frame(maxWidth: 96, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.top, 4)
    }
}

/// Under the island's top row: the waveform and the words while recording, with what the
/// room has turned up and Stop; what the moment was once read; Record when idle.
struct IslandBottom: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.phase {
            case .recording:
                if state.hasWave {
                    LevelBars(levels: state.wave, ink: Brand.record, gap: 2.5, count: 30)
                        .frame(height: 30)
                } else {
                    Text(state.status).font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
                if state.hasWave, !state.line.isEmpty {
                    Text(state.line).font(.footnote).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let r = state.recall {
                        IslandChip(text: r, icon: "arrow.uturn.backward", tint: Brand.notice)
                    } else if let c = state.caught {
                        IslandChip(text: c, icon: "checklist", tint: Brand.act)
                    }
                    Spacer(minLength: 4)
                    if state.paired {
                        Button(intent: StopRecordingIntent()) {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Brand.record, in: Capsule())
                                .foregroundStyle(Brand.onRecord)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .saved:
                Text(state.read ?? "Saved. It's read in a moment.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
            case .ready:
                HStack(spacing: 8) {
                    Text(state.paired ? "Press the side button, or start it here." : "Pair it in the app to start it from here.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                    Spacer(minLength: 4)
                    if state.paired {
                        Button(intent: StartRecordingIntent()) {
                            Label("Record", systemImage: "record.circle")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Brand.record, in: Capsule())
                                .foregroundStyle(Brand.onRecord)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .waiting, .stopped:
                Text(state.status).font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

struct IslandChip: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(tint.opacity(0.22), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Left of the camera when compact: a small live waveform while it records, a tick when
/// saved, the card's light otherwise.
struct CompactLeading: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        Group {
            if state.hasWave {
                LevelBars(levels: Array(state.wave.suffix(5)), ink: Brand.record, gap: 1.5, count: 5)
                    .frame(width: 22, height: 16)
            } else if state.isRecording {
                Image(systemName: "record.circle.fill").foregroundStyle(Brand.record)
            } else if state.phase == .saved {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.act)
            } else {
                LightDot(state: state.light).frame(width: 10, height: 10)
            }
        }
        .padding(.leading, 4)
    }
}

struct MinimalView: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        if state.hasWave {
            LevelBars(levels: Array(state.wave.suffix(3)), ink: Brand.record, gap: 1.5, count: 3)
                .frame(width: 12, height: 12)
        } else if state.isRecording {
            Image(systemName: "record.circle.fill").foregroundStyle(Brand.record)
        } else {
            LightDot(state: state.light).frame(width: 10, height: 10)
        }
    }
}

/// The figure that matters in each phase: the running time while recording, the saved
/// length after, the battery otherwise.
struct TrailingFigure: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording:
            if let since = state.startedAt {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .multilineTextAlignment(.trailing)
            } else {
                Text("…")
            }
        case .saved:
            Text(state.savedSeconds.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? "–")
        case .ready, .waiting, .stopped:
            if let b = state.battery {
                Label("\(b)%", systemImage: batterySymbol(b)).labelStyle(.titleAndIcon)
            } else {
                Text("")
            }
        }
    }
}

func batterySymbol(_ level: Int) -> String {
    switch level {
    case 90...: "battery.100percent"
    case 60...: "battery.75percent"
    case 35...: "battery.50percent"
    case 10...: "battery.25percent"
    default: "battery.0percent"
    }
}

/// The Lock Screen: amber while it records, the card's own colour otherwise. The card and
/// its light on the left; the phase, the timer, the waveform, the words, and Stop or Record.
struct LockScreenView: View {
    let context: ActivityViewContext<RecordingAttributes>

    var body: some View {
        let s = context.state
        let look = PocketLook(advertised: context.attributes.advertised)
        let ink = s.isRecording ? Brand.onRecord : look.ink
        HStack(alignment: .top, spacing: 14) {
            PocketIllustration(fill: look.fill, light: s.lamp)
                .frame(height: 62)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kicker(s)).font(.caption2.weight(.heavy)).tracking(0.6).textCase(.uppercase).opacity(0.75).lineLimit(1)
                        Text(s.isRecording ? (s.context ?? "Recording") : s.headline).font(.headline).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    TrailingFigure(state: s).font(.title2.monospacedDigit().weight(.bold))
                }
                if s.hasWave {
                    LevelBars(levels: s.wave, ink: ink, gap: 2.5, count: 30).frame(height: 26)
                }
                Text(s.status).font(.footnote).opacity(0.85).lineLimit(2)
                if s.isRecording {
                    HStack(spacing: 8) {
                        if let r = s.recall {
                            Label(r, systemImage: "arrow.uturn.backward").font(.caption2.weight(.semibold)).lineLimit(1)
                        } else if let c = s.caught {
                            Label(c, systemImage: "checklist").font(.caption2.weight(.semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if s.paired {
                            Button(intent: StopRecordingIntent()) {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.subheadline.weight(.bold))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Brand.onRecord, in: Capsule())
                                    .foregroundStyle(Brand.record)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if s.phase == .ready, s.paired {
                    HStack {
                        Spacer()
                        Button(intent: StartRecordingIntent()) {
                            Label("Record", systemImage: "record.circle")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Brand.record, in: Capsule())
                                .foregroundStyle(Brand.onRecord)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(ink)
        .padding(16)
    }

    private func kicker(_ s: RecordingAttributes.ContentState) -> String {
        let name = context.attributes.pocketName
        switch s.phase {
        case .recording: return "Recording · \(name)"
        case .saved: return s.read == nil ? "Saved · \(name)" : "Read · \(name)"
        case .ready: return "Ready · \(name)"
        case .waiting: return "Out of range · \(name)"
        case .stopped: return "Stopped · \(name)"
        }
    }
}
