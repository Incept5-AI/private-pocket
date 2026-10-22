import ActivityKit
import Foundation

/// Runs the Live Activity (Dynamic Island, Lock Screen) for the recording in progress.
@MainActor
final class RecordingActivity {
    private var activity: Activity<RecordingAttributes>?

    var isRunning: Bool { activity != nil }

    func start(device: DeviceConfig, startedAt: Date, paired: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end(savedSeconds: nil)
        let attributes = RecordingAttributes(pocketName: device.name, advertised: device.advertisedName)
        let state = RecordingAttributes.ContentState(startedAt: startedAt, line: "", streaming: true, gap: false,
                                                     paired: paired, done: false, savedSeconds: nil)
        activity = try? Activity.request(attributes: attributes,
                                         content: ActivityContent(state: state, staleDate: startedAt.addingTimeInterval(6 * 3_600)),
                                         pushType: nil)
    }

    func update(line: String, streaming: Bool, gap: Bool, paired: Bool) {
        guard let a = activity else { return }
        var s = a.content.state
        guard s.line != line || s.streaming != streaming || s.gap != gap || s.paired != paired else { return }
        s.line = line
        s.streaming = streaming
        s.gap = gap
        s.paired = paired
        Task { await a.update(ActivityContent(state: s, staleDate: s.startedAt.addingTimeInterval(6 * 3_600))) }
    }

    /// Ends it: a saved recording lingers a few seconds with its length, anything else goes at once.
    func end(savedSeconds: Int?) {
        guard let a = activity else { return }
        activity = nil
        var s = a.content.state
        s.done = true
        s.savedSeconds = savedSeconds
        Task {
            await a.end(ActivityContent(state: s, staleDate: nil),
                        dismissalPolicy: savedSeconds == nil ? .immediate : .after(.now + 10))
        }
    }
}
