import AVFoundation
import SwiftUI

/// A few seconds of a recording as a file of its own, to send: the words, who said
/// them and when, sealed in the file's metadata. The one thing here that leaves the
/// phone, and only when the user sends it.
enum Clip {
    struct File: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    static func export(_ r: Recording, from start: Double, to end: Double, words: String) async throws -> File {
        let asset = AVURLAsset(url: r.audioURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.featureUnsupported)
        }
        let safeStart = max(0, start), safeEnd = max(safeStart + 1, end)
        session.timeRange = CMTimeRange(start: CMTime(seconds: safeStart, preferredTimescale: 600),
                                        end: CMTime(seconds: safeEnd, preferredTimescale: 600))
        let when = r.startedAt.map { $0.addingTimeInterval(safeStart).formatted(date: .abbreviated, time: .shortened) } ?? r.day
        session.metadata = [
            item(.commonIdentifierTitle, words),
            item(.commonIdentifierArtist, r.people.isEmpty ? "Private Pocket" : r.people.joined(separator: ", ")),
            item(.commonIdentifierDescription, "Said \(when). A clip from Private Pocket, unaltered."),
        ]
        let name = "Clip " + (r.startedAt?.formatted(.dateTime.day().month(.abbreviated).hour().minute()) ?? r.day) + ".m4a"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(name.replacingOccurrences(of: ":", with: "."))
        try? FileManager.default.removeItem(at: out)
        try await session.export(to: out, as: .m4a)
        return File(url: out)
    }

    private static func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = id
        m.value = value as NSString
        m.extendedLanguageTag = "und"
        return m
    }
}

/// The system share sheet, for a file the page just made.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
