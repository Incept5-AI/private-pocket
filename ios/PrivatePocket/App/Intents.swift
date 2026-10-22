import AppIntents
import Foundation

// The intents themselves live in Shared/RecordingActivity.swift, so the widget
// extension can put them on the Live Activity and in Control Center.

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
