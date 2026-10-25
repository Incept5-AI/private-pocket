import ActivityKit
import AppIntents
import Foundation

// Shared by the app and the widget extension: the Pocket's presence in the Dynamic
// Island and on the Lock Screen, and the Stop button's intent.
//
// iOS only lets an app *start* a Live Activity while it is in the foreground, but it
// can update one from the background. So the activity is started while the app is open
// and the Pocket is connected, shows the card's light and battery, and turns amber
// with the timer when the side button is pressed, even with the phone locked.

struct RecordingAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable { case ready, waiting, recording, working, saved, stopped }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var startedAt: Date?
        /// The latest words of the live transcript.
        var line = ""
        /// The audio is streaming to the phone (false: started before the phone connected).
        var streaming = true
        var gap = false
        /// The phone can stop the recording.
        var paired = true
        var savedSeconds: Int?
        var battery: Int?
        var hoursFree: String?
        /// Once the saved moment is read: its kind and first sentence.
        var read: String?
        /// The last few seconds of loudness, oldest first, 0–15 a bar: the waveform.
        var levels: [UInt8]?
        /// What Record was pressed into: "Into Northlight", "With Maya".
        var context: String?
        /// What the reader has caught so far: "2 to-dos · 1 date caught".
        var caught: String?
        /// A quiet thread named in the room: "Northlight · last spoken 16 Apr".
        var recall: String?
        /// What the app is doing with the recording just stopped: "Saving", "Transcribing",
        /// "Finding voices", "Reading".
        var step: String?
        /// Counts up while it works, one an update, so the swell moves along the bars.
        var beat: Int?
        /// The moment being worked on, by its title.
        var about: String?

        /// The waveform as the views draw it, 0…1.
        var wave: [Float] { (levels ?? []).map { Float($0) / 15 } }

        var isRecording: Bool { phase == .recording }

        /// While it works: a swell travelling along the bars, a step each update, which the
        /// island animates between. 0…1, like the waveform.
        func swell(_ n: Int) -> [Float] {
            let length = max(5, Double(n) * 0.45)
            let b = Double(beat ?? 0)
            return (0..<n).map { i in
                let c = 0.5 + 0.5 * cos(2 * .pi * (Double(i) / length) - b * 0.9)
                return Float(0.2 + 0.7 * c * c)
            }
        }

        var light: LightState {
            switch phase {
            case .ready, .working, .saved, .stopped: .on
            case .waiting: .off
            case .recording: .recording
            }
        }

        var headline: String {
            switch phase {
            case .ready: "Ready"
            case .waiting: "Out of range"
            case .recording: "Recording"
            case .working: step ?? "Saving"
            case .saved: "Saved"
            case .stopped: "Stopped"
            }
        }

        var status: String {
            switch phase {
            case .ready:
                let parts = [battery.map { "Battery \($0)%" }, hoursFree.map { "\($0) free" }].compactMap { $0 }
                return parts.isEmpty ? "Press the side button to record." : parts.joined(separator: " · ")
            case .waiting:
                return "Your Pocket keeps recording on its own. It reconnects when back in range."
            case .recording:
                if !streaming { return "Started before the phone connected. It is fetched when it stops." }
                if gap { return "Stream interrupted. The Pocket keeps recording." }
                return line.isEmpty ? "Streaming to this iPhone" : line
            case .working:
                let what = switch step ?? "" {
                case "Transcribing": "Writing down what was said"
                case "Finding voices": "Telling the voices apart"
                case "Reading": "Reading it for what matters"
                default: "Saving to this iPhone"
                }
                return [about, savedSeconds.map { PocketFacts.length($0) }, what].compactMap { $0 }.joined(separator: " · ")
            case .saved:
                return read ?? savedSeconds.map { "Saved on this iPhone · \(PocketFacts.length($0))" } ?? "Saved on this iPhone"
            case .stopped:
                return "Stopped. It is fetched when the phone connects."
            }
        }
    }

    var pocketName: String
    var advertised: String
}

/// The Stop button on the Live Activity and in Control Center. Performed in the app,
/// which holds the Bluetooth link; the app installs `handler` at launch. (Live Activity
/// intents are among the few kinds Control Center runs in the app rather than in the
/// extension.)
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop recording"
    static let description = IntentDescription("Stops the recording on your Pocket.")

    nonisolated(unsafe) static var handler: (@MainActor () async throws -> Void)?

    func perform() async throws -> some IntentResult {
        try await Self.handler?()
        return .result()
    }
}

/// Control Center's one toggle: on starts a recording, off stops it. Performed in the
/// app, like the two above.
struct ToggleRecordingIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Pocket recording"
    static let description = IntentDescription("Starts or stops recording on your Pocket, like its side button.")

    @Parameter(title: "Recording") var value: Bool

    nonisolated(unsafe) static var handler: (@MainActor (Bool) async throws -> Void)?

    func perform() async throws -> some IntentResult {
        try await Self.handler?(value)
        return .result()
    }
}

/// "Start recording on Private Pocket": Siri, Shortcuts and the Action button. Same
/// arrangement as Stop.
struct StartRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start recording"
    static let description = IntentDescription("Starts a recording on your Pocket, like pressing its side button.")

    nonisolated(unsafe) static var handler: (@MainActor () async throws -> Void)?

    func perform() async throws -> some IntentResult {
        try await Self.handler?()
        return .result()
    }
}
