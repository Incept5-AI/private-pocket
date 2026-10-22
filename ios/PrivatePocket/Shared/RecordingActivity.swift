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
    enum Phase: String, Codable, Hashable { case ready, waiting, recording, saved, stopped }

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

        var isRecording: Bool { phase == .recording }

        var light: LightState {
            switch phase {
            case .ready, .saved, .stopped: .on
            case .waiting: .off
            case .recording: .recording
            }
        }

        var headline: String {
            switch phase {
            case .ready: "Ready"
            case .waiting: "Out of range"
            case .recording: "Recording"
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
            case .saved:
                return savedSeconds.map { "Saved on this iPhone · \(PocketFacts.length($0))" } ?? "Saved on this iPhone"
            case .stopped:
                return "Stopped. It is fetched when the phone connects."
            }
        }
    }

    var pocketName: String
    var advertised: String
}

/// The Stop button on the Live Activity. Performed in the app, which holds the
/// Bluetooth link; the app installs `handler` at launch.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop recording"
    static let description = IntentDescription("Stops the recording on your Pocket.")

    nonisolated(unsafe) static var handler: (@MainActor () async -> Void)?

    func perform() async throws -> some IntentResult {
        await Self.handler?()
        return .result()
    }
}
