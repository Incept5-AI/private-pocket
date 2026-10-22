import AppIntents
import Foundation

/// "Start recording on Private Pocket": Siri, Shortcuts and the Action button. Runs in
/// the app, which holds the Bluetooth link; `handler` is installed at launch.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start recording"
    static let description = IntentDescription("Starts a recording on your Pocket, like pressing its side button.")
    static let openAppWhenRun = false

    nonisolated(unsafe) static var handler: (@MainActor () async throws -> Void)?

    func perform() async throws -> some IntentResult {
        try await Self.handler?()
        return .result()
    }
}

struct PocketShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording on \(.applicationName)", "Record with \(.applicationName)"],
                    shortTitle: "Start recording", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["Stop recording on \(.applicationName)"],
                    shortTitle: "Stop recording", systemImageName: "stop.circle")
    }
}

/// Thrown to Siri when the Pocket cannot be reached.
struct PocketIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
