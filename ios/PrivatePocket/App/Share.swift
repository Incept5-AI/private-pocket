import SwiftUI

/// A moment as files to send: the recording, the transcript, or both in one zip, each
/// named for the moment rather than the card's timestamp. Made in a temporary folder when
/// asked for; nothing leaves the phone until the person sends it.
enum MomentShare {
    enum Kind { case audio, transcript, both }

    /// Shared files, the export zip and clips, an hour after they were made: the share sheet
    /// has long finished with them, and the app can stay running for days.
    static func sweep() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-3600)
        for u in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let name = u.lastPathComponent
            guard name.hasPrefix("Share-") || name == "Private Pocket moments.zip" || (name.hasPrefix("Clip ") && name.hasSuffix(".m4a")) else { continue }
            let made = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if made < cutoff { try? fm.removeItem(at: u) }
        }
    }

    /// "Workshop with Maya 2026-10-23 13.02": the moment's title and when, safe as a file name.
    static func baseName(_ r: Recording) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>“”").union(.newlines)
        let title = r.quote.components(separatedBy: bad).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let short = title.count > 60 ? String(title.prefix(60)).trimmingCharacters(in: .whitespaces) : title
        let when = r.startedAt.map { d -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH.mm"
            return f.string(from: d)
        } ?? r.day
        return short.isEmpty ? "Moment \(when)" : "\(short) \(when)"
    }

    /// The transcript with a heading: what it was, when, how long, who. Speakers and times
    /// when there were two or more.
    static func transcriptText(_ r: Recording) -> String? {
        guard let body = r.transcriptForModel?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        var line = [r.startedAt?.formatted(date: .complete, time: .shortened)].compactMap { $0 }
        if let s = r.meta.seconds { line.append(PocketFacts.length(s)) }
        if !r.people.isEmpty { line.append("with " + r.people.joined(separator: ", ")) }
        return [r.quote, line.joined(separator: " · "), "Recorded with Private Pocket.", "", body].joined(separator: "\n") + "\n"
    }

    /// The file to hand to the share sheet.
    static func file(_ kind: Kind, for r: Recording) async throws -> URL {
        let base = baseName(r)
        let audio = r.audioURL
        let text = transcriptText(r)
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            switch kind {
            case .audio:
                let out = dir.appendingPathComponent(base + ".mp3")
                try fm.copyItem(at: audio, to: out)
                return out
            case .transcript:
                guard let text else { throw CocoaError(.fileReadNoSuchFile) }
                let out = dir.appendingPathComponent(base + ".txt")
                try text.write(to: out, atomically: true, encoding: .utf8)
                return out
            case .both:
                let folder = dir.appendingPathComponent(base, isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.copyItem(at: audio, to: folder.appendingPathComponent(base + ".mp3"))
                if let text { try text.write(to: folder.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8) }
                let out = dir.appendingPathComponent(base + ".zip")
                var copyError: Error?
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { zipped in
                    do { try fm.copyItem(at: zipped, to: out) } catch { copyError = error }
                }
                if let e = coordError ?? copyError { throw e }
                return out
            }
        }.value
    }
}

/// Share a moment: a menu of the recording, the transcript, or both as a zip, then the
/// system share sheet with the file.
struct MomentShareMenu<Content: View>: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    @ViewBuilder var label: () -> Content
    @State private var file: Clip.File?
    @State private var preparing = false

    var body: some View {
        Menu {
            Section("Share") {
                Button { prepare(.audio) } label: { Label("The recording", systemImage: "waveform") }
                if recording.meta.transcript != nil {
                    Button { prepare(.transcript) } label: { Label("The transcript", systemImage: "text.quote") }
                    Button { prepare(.both) } label: { Label("Both, as a zip", systemImage: "doc.zipper") }
                }
            }
        } label: {
            label()
        }
        .disabled(preparing)
        .sheet(item: $file) { f in
            ShareSheet(items: [f.url]).presentationDetents([.medium, .large]).ignoresSafeArea()
        }
    }

    private func prepare(_ kind: MomentShare.Kind) {
        preparing = true
        Task {
            defer { preparing = false }
            do {
                file = Clip.File(url: try await MomentShare.file(kind, for: recording))
            } catch {
                model.aiError = "That couldn't be made ready to share. Try again in a moment."
            }
        }
    }
}
