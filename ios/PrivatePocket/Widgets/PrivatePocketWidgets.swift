import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PrivatePocketWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// While the Pocket records: the amber light, the timer and the latest words, in the
/// Dynamic Island and on the Lock Screen, with Stop when the phone can stop it.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(PocketLook(advertised: context.attributes.advertised).fill)
                .activitySystemActionForegroundColor(PocketLook(advertised: context.attributes.advertised).ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        LightDot(state: context.state.done ? .on : .recording).frame(width: 12, height: 12)
                        Text(context.attributes.pocketName).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTimer(state: context.state)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(context.state.status)
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        if context.state.paired, !context.state.done {
                            Button(intent: StopRecordingIntent()) {
                                Image(systemName: "stop.fill").font(.body.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent).tint(.orange)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                LightDot(state: context.state.done ? .on : .recording).frame(width: 10, height: 10).padding(.leading, 6)
            } compactTrailing: {
                RecordingTimer(state: context.state)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 52).padding(.trailing, 2)
            } minimal: {
                LightDot(state: context.state.done ? .on : .recording).frame(width: 10, height: 10)
            }
            .keylineTint(.orange)
        }
    }
}

/// The running time while recording, the saved length afterwards.
struct RecordingTimer: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        if state.done {
            Text(state.savedSeconds.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? "–")
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<RecordingAttributes>

    var body: some View {
        let look = PocketLook(advertised: context.attributes.advertised)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LightDot(state: context.state.done ? .on : .recording).frame(width: 12, height: 12)
                Text(context.state.done ? "Saved" : "Recording").font(.headline).foregroundStyle(look.ink)
                Text("· \(context.attributes.pocketName)").font(.subheadline).foregroundStyle(look.ink.opacity(0.7))
                Spacer()
                RecordingTimer(state: context.state)
                    .font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(look.ink)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(context.state.status)
                    .font(.footnote).foregroundStyle(look.ink.opacity(0.85)).lineLimit(2)
                Spacer()
                if context.state.paired, !context.state.done {
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
