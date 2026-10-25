import ActivityKit
import Foundation

/// The Pocket's presence in the Dynamic Island and on the Lock Screen. Started while
/// the app is in the foreground and the Pocket is connected (iOS allows no other
/// start), then updated from anywhere: amber with the timer while the side button
/// records, a lilac swell while the app saves, transcribes and reads what it recorded,
/// "Saved" or what was read for a moment after, back to the light and battery.
@MainActor
final class RecordingActivity {
    private var activity: Activity<RecordingAttributes>?
    private var revert: Task<Void, Never>?
    /// The beat while it works: an update every second and a half, so the swell moves.
    private var beats: Task<Void, Never>?
    /// Log line for the protocol log.
    var note: ((String) -> Void)?

    private var current: RecordingAttributes.ContentState? {
        guard let a = activity, a.activityState == .active else { return nil }
        return a.content.state
    }

    var isRecording: Bool { current?.isRecording == true }

    /// An activity left by an earlier run of the app (closed, or killed while it recorded) is
    /// taken up again rather than orphaned; any others end.
    init() {
        let all = Activity<RecordingAttributes>.activities
        activity = all.first { $0.activityState == .active }
        for a in all where a.id != activity?.id {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Stopped and being saved: the timer stops at once rather than running on through the
    /// save, and the swell starts.
    func showSaving() {
        guard var s = current, s.isRecording else { return }
        s.phase = .working
        s.step = Step.saving.rawValue
        s.startedAt = nil
        s.levels = nil
        s.caught = nil
        s.recall = nil
        update(s)
        startBeats()
    }

    enum Step: String { case saving = "Saving", transcribing = "Transcribing", voices = "Finding voices", reading = "Reading" }

    /// The recording just stopped is being worked on: what is happening to it, with the
    /// swell. Not over a recording, which keeps the island.
    func showWorking(_ step: Step, seconds: Int?) {
        guard var s = current, !s.isRecording else { return }
        revert?.cancel()
        s.phase = .working
        s.step = step.rawValue
        if let seconds { s.savedSeconds = seconds }
        s.read = nil
        update(s)
        startBeats()
    }

    var isWorking: Bool { current?.phase == .working }

    /// Which beat is running, so a beat that ends never clears the one that replaced it.
    private var beatRun = 0

    private func startBeats() {
        guard beats == nil else { return }
        beatRun += 1
        let run = beatRun, began = Date()
        beats = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled, var s = self.current, s.phase == .working else { break }
                // Nothing takes a quarter of an hour; if it seems to, the island stops saying so.
                if Date().timeIntervalSince(began) > 900 {
                    self.showStopped(savedSeconds: s.savedSeconds, keepPresence: Prefs.islandPresence, force: true)
                    return
                }
                s.beat = ((s.beat ?? 0) + 1) % 1_000
                self.update(s)
            }
            if let self, self.beatRun == run { self.beats = nil }
        }
    }

    private func stopBeats() {
        beats?.cancel()
        beats = nil
    }

    /// A recording shown by an earlier run of the app that is not going on: back to ready.
    func clearRecording() {
        guard var s = current, s.isRecording || s.phase == .working else { return }
        stopBeats()
        s.phase = .ready
        s.startedAt = nil
        s.line = ""
        s.levels = nil
        s.context = nil
        s.caught = nil
        s.recall = nil
        update(s)
    }

    /// Connected and idle. Starts the activity if there is none (foreground only).
    func showReady(device: DeviceConfig, battery: Int?, hoursFree: String?, paired: Bool = true) {
        var s = current ?? .init(phase: .ready)
        guard !s.isRecording else { return }
        if s.phase == .working {   // the app is still at work on what it recorded: that stays
            s.battery = battery
            s.hoursFree = hoursFree
            s.paired = paired
            update(s)
            return
        }
        revert?.cancel()
        s.phase = .ready
        s.startedAt = nil
        s.savedSeconds = nil
        s.battery = battery
        s.hoursFree = hoursFree
        s.paired = paired
        s.levels = nil
        s.context = nil
        s.caught = nil
        s.recall = nil
        push(s, device: device)
    }

    /// The link dropped: the Pocket is on its own until it is back in range.
    func showWaiting() {
        guard var s = current, !s.isRecording, s.phase != .working else { return }
        s.phase = .waiting
        update(s)
    }

    func showRecording(device: DeviceConfig, startedAt: Date, paired: Bool, context: String? = nil) {
        revert?.cancel()
        stopBeats()
        var s = current ?? .init(phase: .recording)
        s.phase = .recording
        s.startedAt = startedAt
        s.paired = paired
        s.line = ""
        s.streaming = true
        s.gap = false
        s.savedSeconds = nil
        s.read = nil
        s.levels = []
        s.context = context
        s.caught = nil
        s.recall = nil
        s.step = nil
        push(s, device: device)
    }

    /// Every two seconds while it records: the words, the waveform, and what the room has
    /// turned up so far. Sent only when something changed.
    func updateRecording(line: String, streaming: Bool, gap: Bool, paired: Bool,
                         levels: [UInt8]? = nil, context: String? = nil, caught: String? = nil, recall: String? = nil) {
        guard var s = current, s.isRecording else { return }
        guard s.line != line || s.streaming != streaming || s.gap != gap || s.paired != paired
            || s.levels != levels || s.context != context || s.caught != caught || s.recall != recall else { return }
        s.line = line
        s.streaming = streaming
        s.gap = gap
        s.paired = paired
        s.levels = levels
        s.context = context
        s.caught = caught
        s.recall = recall
        update(s)
    }

    /// Stopped: shows the saved length for a moment, then goes back to ready. While the app
    /// is already transcribing or reading it, only the length is taken, unless `force`d: the
    /// work is over.
    func showStopped(savedSeconds: Int?, keepPresence: Bool, force: Bool = false) {
        guard var s = current, !s.isRecording else { return }
        if !force, s.phase == .working, s.step != Step.saving.rawValue {
            if let savedSeconds { s.savedSeconds = savedSeconds }
            update(s)
            return
        }
        stopBeats()
        s.step = nil
        s.phase = savedSeconds == nil ? .stopped : .saved
        s.savedSeconds = savedSeconds
        s.startedAt = nil
        s.line = ""
        s.read = nil
        s.levels = nil
        s.caught = nil
        s.recall = nil
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

    /// The recording the last Saved was about, so its reading can follow it there.
    var lastSavedName: String?

    /// Once the saved moment is read: its kind and first sentence, where the person is.
    func showRead(_ text: String) {
        guard var s = current, s.phase == .saved || s.phase == .working else { return }
        stopBeats()
        lastSavedName = nil   // read: a later reading of it keeps out of the island
        s.phase = .saved
        s.step = nil
        s.read = text
        update(s)
        revert?.cancel()
        revert = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, var r = self.current, !r.isRecording else { return }
            if Prefs.islandPresence {
                r.phase = .ready
                r.savedSeconds = nil
                r.read = nil
                self.update(r)
            } else {
                self.end()
            }
        }
    }

    func end() {
        revert?.cancel()
        stopBeats()
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
