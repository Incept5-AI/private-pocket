import AVFoundation
import SwiftUI

/// Listen back: the sentences that mattered, played one after another from the
/// recordings they came from, a few seconds each. Yesterday in three minutes.
@MainActor
final class Replay: NSObject, ObservableObject {
    struct Line {
        let url: URL
        let at: Double
        let text: String
    }

    @Published private(set) var playing = false
    @Published private(set) var index = 0
    @Published private(set) var lines: [Line] = []
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let seconds: Double = 8

    var current: Line? { playing && lines.indices.contains(index) ? lines[index] : nil }

    /// The anchored sentences of these moments, in the order they were said.
    static func lines(from moments: [Recording]) -> [Line] {
        var out: [Line] = []
        for r in moments.sorted(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) {
            let anchored = ((r.meta.insight?.brief ?? []) + (r.meta.insight?.keyLines ?? [])).compactMap { a -> Line? in
                guard let at = a.at else { return nil }
                return Line(url: r.audioURL, at: max(0, at - 0.5), text: a.text)
            }
            var seen = Set<Int>()
            for l in anchored.sorted(by: { $0.at < $1.at }) where seen.insert(Int(l.at / 6)).inserted { out.append(l) }
        }
        return out
    }

    func play(_ lines: [Line]) {
        stop()
        guard !lines.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        self.lines = lines
        index = 0
        playing = true
        playCurrent()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playing = false
    }

    private func playCurrent() {
        guard lines.indices.contains(index) else { stop(); return }
        let l = lines[index]
        guard let p = try? AVAudioPlayer(contentsOf: l.url) else { next(); return }
        player = p
        p.currentTime = min(l.at, max(0, p.duration - 1))
        p.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
    }

    private func next() {
        index += 1
        if lines.indices.contains(index) { playCurrent() } else { stop() }
    }
}
