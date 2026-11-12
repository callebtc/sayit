import ArgumentParser
import Foundation

struct CLIExportDestination {
    let url: URL

    init(path: String) throws {
        guard !path.isEmpty else {
            throw ValidationError("Provide a WAV file path with --output.")
        }
        let expanded = (path as NSString).expandingTildeInPath
        url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.pathExtension.lowercased() == "wav" else {
            throw ValidationError("Use a .wav file path with --output.")
        }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else {
            throw ValidationError("The output file already exists. Choose a new path.")
        }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue, manager.isWritableFile(atPath: parent.path) else {
            throw ValidationError("The output directory must exist and be writable.")
        }
    }

    func write(_ data: Data) throws {
        let staging = url.deletingLastPathComponent()
            .appending(path: ".sayit-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .withoutOverwriting)
        // Moving into place refuses to replace a file created since validation.
        try FileManager.default.moveItem(at: staging, to: url)
    }
}
