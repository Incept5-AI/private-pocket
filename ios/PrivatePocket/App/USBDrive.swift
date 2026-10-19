import Foundation

/// A Pocket mounted over USB-C (Web Sync on, cable re-plugged) and opened with the
/// Files picker. Files live at `RECORD/<yyyy-MM-dd>/<yyyyMMddHHmmss>.mp3`.
struct DriveFile: Identifiable, Hashable {
    let url: URL
    let day: String
    let name: String
    let size: Int
    var id: URL { url }
}

@MainActor
final class USBDrive: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var files: [DriveFile] = []
    @Published var error: String?

    private var accessing: URL?

    func open(_ picked: URL) {
        close()
        guard picked.startAccessingSecurityScopedResource() else {
            error = "iOS did not grant access to that folder."
            return
        }
        accessing = picked
        let record = picked.appendingPathComponent("RECORD", isDirectory: true)
        if FileManager.default.fileExists(atPath: record.path) {
            root = record
        } else if picked.lastPathComponent == "RECORD" {
            root = picked
        } else {
            error = "No RECORD folder there. Choose the Pocket drive itself."
            close()
            return
        }
        refresh()
    }

    func close() {
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
        root = nil
        files = []
    }

    func refresh() {
        guard let root else { return }
        let fm = FileManager.default
        var out: [DriveFile] = []
        for dayDir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            where f.pathExtension.lowercased() == "mp3" && !f.lastPathComponent.hasPrefix("._") {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                out.append(DriveFile(url: f, day: dayDir.lastPathComponent,
                                     name: f.deletingPathExtension().lastPathComponent, size: size))
            }
        }
        files = out.sorted { $0.name > $1.name }
    }

    func delete(_ list: [DriveFile]) {
        for f in list {
            do {
                try FileManager.default.removeItem(at: f.url)
                let dot = f.url.deletingLastPathComponent().appendingPathComponent("._" + f.url.lastPathComponent)
                try? FileManager.default.removeItem(at: dot)
            } catch {
                self.error = "Could not delete \(f.name): \(error.localizedDescription)"
            }
        }
        refresh()
    }

    func read(_ f: DriveFile) throws -> Data { try Data(contentsOf: f.url) }
}
