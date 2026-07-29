import Darwin
import Foundation

public enum ParentProcessFile {
    public static let filename = "parent.pid"

    public static func write(pid: pid_t, in directory: URL) {
        let url = directory.appending(path: filename)
        try? Data("\(pid)\n".utf8).write(to: url, options: .atomic)
    }

    public static func remove(from directory: URL) {
        try? FileManager.default.removeItem(
            at: directory.appending(path: filename)
        )
    }

    public static func readPID(from directory: URL) -> pid_t? {
        guard let data = try? Data(
            contentsOf: directory.appending(path: filename)
        ),
        let text = String(
            decoding: data, as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
        let pid = Int32(text) else {
            return nil
        }
        return pid
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
