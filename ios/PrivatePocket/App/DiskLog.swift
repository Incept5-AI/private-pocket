import Foundation

/// The protocol log, on disk as well as in memory: `Documents/pocket-log.txt`, which
/// the Files app shows and Pocket details can share. Appended line by line; trimmed to
/// its last 200 KB when it passes 600 KB.
enum DiskLog {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pocket-log.txt")
    private static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func append(_ line: String) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        guard let h = handle else { return }
        try? h.write(contentsOf: Data("\(stamp.string(from: Date()))  \(line)\n".utf8))
        if let size = try? h.offset(), size > 600_000 { trim() }
    }

    private static func trim() {
        try? handle?.close()
        handle = nil
        guard let data = try? Data(contentsOf: url) else { return }
        try? data.suffix(200_000).write(to: url)
    }
}
