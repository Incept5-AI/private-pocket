import ActivityKit
import AppIntents
import Foundation

// Shared by the app and the widget extension: the Live Activity shown in the Dynamic
// Island and on the Lock Screen while the Pocket records, and the Stop button's intent.

struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        /// The latest words of the live transcript.
        var line: String
        /// The audio is streaming to the phone (false: started before the phone connected).
        var streaming: Bool
        var gap: Bool
        /// The phone can stop the recording.
        var paired: Bool
        /// Stopped and saved (`savedSeconds`), or stopped without a copy on the phone.
        var done: Bool
        var savedSeconds: Int?

        var status: String {
            if done {
                if let s = savedSeconds { return "Saved on this iPhone · \(PocketFacts.length(s))" }
                return "Stopped"
            }
            if !streaming { return "Started before the phone connected. It is fetched when it stops." }
            if gap { return "Stream interrupted. The Pocket keeps recording." }
            return line.isEmpty ? "Streaming to this iPhone" : line
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
