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
            .tint(.orange)
        }
        .displayName("Pocket")
        .description("Starts or stops recording on your Pocket, like its side button.")
    }
}

struct RecordingStateProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { SharedState.recording }
}

/// The Pocket in the Dynamic Island and on the Lock Screen: its light and battery
/// while connected, the timer and the latest words while it records, with Stop when
/// the phone can stop it.
struct PocketLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(PocketLook(advertised: context.attributes.advertised).fill)
                .activitySystemActionForegroundColor(PocketLook(advertised: context.attributes.advertised).ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        LightDot(state: context.state.light).frame(width: 12, height: 12)
                        Text(context.state.isRecording ? "Recording" : context.attributes.pocketName)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingFigure(state: context.state)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(context.state.status)
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        if context.state.isRecording, context.state.paired {
                            Button(intent: StopRecordingIntent()) {
                                Image(systemName: "stop.fill").font(.body.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent).tint(.orange)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                LightDot(state: context.state.light).frame(width: 10, height: 10).padding(.leading, 6)
            } compactTrailing: {
                TrailingFigure(state: context.state)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 52).padding(.trailing, 2)
            } minimal: {
                LightDot(state: context.state.light).frame(width: 10, height: 10)
            }
            .keylineTint(context.state.isRecording ? .orange : .blue)
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

struct LockScreenView: View {
    let context: ActivityViewContext<RecordingAttributes>

    var body: some View {
        let look = PocketLook(advertised: context.attributes.advertised)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LightDot(state: context.state.light).frame(width: 12, height: 12)
                Text(context.state.headline).font(.headline).foregroundStyle(look.ink)
                Text("· \(context.attributes.pocketName)").font(.subheadline).foregroundStyle(look.ink.opacity(0.7))
                Spacer()
                TrailingFigure(state: context.state)
                    .font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(look.ink)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(context.state.status)
                    .font(.footnote).foregroundStyle(look.ink.opacity(0.85)).lineLimit(2)
                Spacer()
                if context.state.isRecording, context.state.paired {
                    Button(intent: StopRecordingIntent()) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                }
            }
        }
        .padding(16)
    }
}
