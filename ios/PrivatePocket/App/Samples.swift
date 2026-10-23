import Foundation

/// A sample moment bundled with the app (Samples/manifest.json, built by Samples/make.py).
struct SampleMoment: Codable, Identifiable {
    var id: String
    var title: String
    /// The kind a reading of it is expected to say.
    var kind: String
    var mode: String
    var file: String
}

/// Eight short spoken conversations, one per kind, in the Pocket's own format, so the
/// whole path, speech to text, reading, Moments and Insights, can run on this iPhone or
/// a server without a Pocket in hand, and be checked against what each was meant to be.
enum SampleMoments {
    static let pocketName = "Sample Pocket"
    static let advertisedName = "PKT01_SAMPLE_00000000"

    static func all() -> [SampleMoment] {
        struct Manifest: Decodable { let samples: [SampleMoment] }
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "SampleMoments"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(Manifest.self, from: data))?.samples ?? []
    }

    static func audioURL(_ s: SampleMoment) -> URL? {
        Bundle.main.url(forResource: s.file, withExtension: nil, subdirectory: "SampleMoments")
    }
}

extension AppModel {
    /// The sample as it is on this phone, if it was added.
    func sampleRecording(_ s: SampleMoment) -> Recording? {
        library.recordings.first { $0.meta.sampleID == s.id }
    }

    /// Adds the samples as recordings through the normal path, dated over the last few
    /// hours, then transcribes and reads each in turn with whatever speech to text and
    /// language model are set, so they appear in Moments and Insights as real ones do.
    func addSamples() async {
        let samples = SampleMoments.all()
        let device = devices.selected
        let deviceID = device?.id ?? UUID(uuidString: "00000000-0000-0000-0000-00000000A11E")!
        let pocket = device.map(pocketID)
            ?? PocketID(DeviceConfig(name: SampleMoments.pocketName, advertisedName: SampleMoments.advertisedName, peripheralID: nil))
        var added: [Recording] = []
        for (i, s) in samples.enumerated() where sampleRecording(s) == nil {
            guard let url = SampleMoments.audioURL(s), let audio = try? Data(contentsOf: url) else { continue }
            // Spread over the last eleven days, a day and a half apart, so Insights has a
            // week to compare with and promises that have had time to fall due.
            let start = Date().addingTimeInterval(-Double(samples.count - 1 - i) * 36 * 3600 - 2 * 3600)
            let name = s.mode == "CALL" ? "PH" + PocketTime.shortName.string(from: start) : PocketTime.fileName.string(from: start)
            do {
                var r = try library.save(device: deviceID, day: PocketTime.day.string(from: start), name: name, audio: audio,
                                         seconds: Int((Self.duration(of: audio) ?? 0).rounded()), pocket: pocket)
                r.meta.mode = s.mode
                r.meta.sampleID = s.id
                r.meta.expectedKind = s.kind
                library.update(r)
                added.append(r)
            } catch {
                aiError = "\(s.title) couldn't be added. Try again."
            }
        }
        for r in added { await transcribe(r) }
    }

    /// Transcribes and reads every sample again, with the current settings.
    func rerunSamples() async {
        for s in SampleMoments.all() {
            if let r = sampleRecording(s) { await transcribe(r) }
        }
    }

    /// Reads every sample again, keeping the transcripts: for trying a change to the reader.
    func rereadSamples() async {
        for s in SampleMoments.all() {
            if let r = sampleRecording(s), r.meta.transcript != nil { await analyse(r, quiet: true) }
        }
    }

    func removeSamples() {
        for r in library.recordings where r.meta.sampleID != nil {
            for item in r.meta.insight?.next ?? [] {
                if let id = item.reminderID { Planner.removeReminder(id) }
                if let id = item.eventID { Planner.removeEvent(id) }
            }
            library.delete(r)
        }
    }

    /// Samples added before they were spread over eleven days are added again, once.
    func respreadSamples() async {
        guard !UserDefaults.standard.bool(forKey: "samplesSpread") else { return }
        UserDefaults.standard.set(true, forKey: "samplesSpread")
        guard library.recordings.contains(where: { $0.meta.sampleID != nil }) else { return }
        removeSamples()
        await addSamples()
    }

    /// Your correction of what a moment was; nil goes back to the model's reading.
    func setKind(_ r: Recording, _ kind: MomentKind?) {
        var r = r
        r.meta.labelKind = kind?.rawValue
        library.update(r)
    }
}
