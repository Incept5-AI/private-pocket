import ActivityKit
import Foundation

/// The Pocket's presence in the Dynamic Island and on the Lock Screen. Started while
/// the app is in the foreground and the Pocket is connected (iOS allows no other
/// start), then updated from anywhere: amber with the timer while the side button
/// records, "Saved" for a moment after, back to the light and battery.
@MainActor
final class RecordingActivity {
    private var activity: Activity<RecordingAttributes>?
    private var revert: Task<Void, Never>?
    /// Log line for the protocol log.
    var note: ((String) -> Void)?

    private var current: RecordingAttributes.ContentState? {
        guard let a = activity, a.activityState == .active else { return nil }
        return a.content.state
    }

    var isRecording: Bool { current?.isRecording == true }

    /// Connected and idle. Starts the activity if there is none (foreground only).
    func showReady(device: DeviceConfig, battery: Int?, hoursFree: String?) {
        revert?.cancel()
        var s = current ?? .init(phase: .ready)
        guard !s.isRecording else { return }
        s.phase = .ready
        s.startedAt = nil
        s.savedSeconds = nil
        s.battery = battery
        s.hoursFree = hoursFree
        push(s, device: device)
    }

    /// The link dropped: the Pocket is on its own until it is back in range.
    func showWaiting() {
        guard var s = current, !s.isRecording else { return }
        s.phase = .waiting
        update(s)
    }

    func showRecording(device: DeviceConfig, startedAt: Date, paired: Bool) {
        revert?.cancel()
        var s = current ?? .init(phase: .recording)
        s.phase = .recording
        s.startedAt = startedAt
        s.paired = paired
        s.line = ""
        s.streaming = true
        s.gap = false
        s.savedSeconds = nil
        push(s, device: device)
    }

    func updateRecording(line: String, streaming: Bool, gap: Bool, paired: Bool) {
        guard var s = current, s.isRecording else { return }
        guard s.line != line || s.streaming != streaming || s.gap != gap || s.paired != paired else { return }
        s.line = line
        s.streaming = streaming
        s.gap = gap
        s.paired = paired
        update(s)
    }

    /// Stopped: shows the saved length for a moment, then goes back to ready.
    func showStopped(savedSeconds: Int?, keepPresence: Bool) {
        guard var s = current else { return }
        s.phase = savedSeconds == nil ? .stopped : .saved
        s.savedSeconds = savedSeconds
        s.startedAt = nil
        s.line = ""
        update(s)
        revert?.cancel()
        revert = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            if keepPresence, var r = self.current, !r.isRecording {
                r.phase = .ready
                r.savedSeconds = nil
                self.update(r)
            } else {
                self.end()
            }
        }
    }

    func end() {
        revert?.cancel()
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    private func push(_ s: RecordingAttributes.ContentState, device: DeviceConfig) {
        if let a = activity, a.activityState == .active {
            if a.attributes.advertised == device.advertisedName { update(s); return }
            end()   // another Pocket: start afresh
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = RecordingAttributes(pocketName: device.name, advertised: device.advertisedName)
        do {
            activity = try Activity.request(attributes: attributes, content: content(s), pushType: nil)
            note?("Live Activity started")
        } catch {
            note?("Live Activity not started: \(error.localizedDescription)")
        }
    }

    private func update(_ s: RecordingAttributes.ContentState) {
        guard let a = activity else { return }
        Task { await a.update(content(s)) }
    }

    private func content(_ s: RecordingAttributes.ContentState) -> ActivityContent<RecordingAttributes.ContentState> {
        ActivityContent(state: s, staleDate: Date().addingTimeInterval(8 * 3_600))
    }
}
