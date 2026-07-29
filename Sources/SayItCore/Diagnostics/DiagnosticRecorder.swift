import Foundation

public actor DiagnosticRecorder {
    public static let maximumByteCount: Int64 = 10 * 1_024 * 1_024
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL
    private var recentEvents: [DiagnosticEvent] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let contents = String(data: data, encoding: .utf8) {
            recentEvents = contents
                .split(separator: "\n")
                .suffix(500)
                .compactMap { line in
                    try? JSONDecoder.sayIt.decode(
                        DiagnosticEvent.self,
                        from: Data(line.utf8)
                    )
                }
        }
    }

    public func record(_ event: DiagnosticEvent) async {
        guard Self.isSafeCode(event.code) else { return }
        recentEvents.append(event)
        if recentEvents.count > 500 {
            recentEvents.removeFirst(recentEvents.count - 500)
        }

        do {
            try rotateIfNeeded()
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            var data = try JSONEncoder.sayIt.encode(event)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }
        } catch {
            // Diagnostics must never disrupt the user-facing operation.
        }
    }

    public func events() -> [DiagnosticEvent] {
        recentEvents
    }

    public func clear() throws {
        recentEvents.removeAll(keepingCapacity: false)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public static func isSafeCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= 64 else { return false }
        return code.allSatisfy { character in
            character.isASCII
                && (character.isLowercase
                    || character.isNumber
                    || character == "."
                    || character == "_")
        }
    }

    private func rotateIfNeeded() throws {
        let values = try? fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let isOversized = Int64(values?.fileSize ?? 0) >= Self.maximumByteCount
        let isExpired = values?.contentModificationDate.map {
            Date.now.timeIntervalSince($0) >= Self.maximumAge
        } ?? false
        if isOversized || isExpired {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
