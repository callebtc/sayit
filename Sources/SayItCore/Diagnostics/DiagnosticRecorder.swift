import Foundation

public actor DiagnosticRecorder {
    public static let maximumByteCount: Int64 = 10 * 1_024 * 1_024
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL
    private var recentEvents: [DiagnosticEvent] = []
    private var writeHandle: FileHandle?
    private var currentByteCount: Int64 = 0
    private var lastModifiedAt: Date?
    private var parentDirectoryCreated = false

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

    deinit {
        try? writeHandle?.close()
    }

    public func record(_ event: DiagnosticEvent) async {
        guard Self.isSafeCode(event.code) else { return }
        recentEvents.append(event)
        if recentEvents.count > 500 {
            recentEvents.removeFirst(recentEvents.count - 500)
        }

        do {
            try rotateIfNeeded()
            if !parentDirectoryCreated {
                let parent = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                parentDirectoryCreated = true
            }
            var data = try JSONEncoder.sayIt.encode(event)
            data.append(0x0A)
            if let handle = writeHandle {
                do {
                    try handle.write(contentsOf: data)
                    currentByteCount += Int64(data.count)
                    lastModifiedAt = .now
                    return
                } catch {
                    closeHandle()
                }
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
                currentByteCount = Int64(data.count)
                lastModifiedAt = .now
                openAppendHandle()
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                let endOffset = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                writeHandle = handle
                currentByteCount = Int64(endOffset) + Int64(data.count)
                lastModifiedAt = .now
            }
        } catch {
            closeHandle()
            // Diagnostics must never disrupt the user-facing operation.
        }
    }

    public func events() -> [DiagnosticEvent] {
        recentEvents
    }

    public func clear() throws {
        recentEvents.removeAll(keepingCapacity: false)
        closeHandle()
        currentByteCount = 0
        lastModifiedAt = nil
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

    private func openAppendHandle() {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        _ = try? handle.seekToEnd()
        writeHandle = handle
    }

    private func closeHandle() {
        try? writeHandle?.close()
        writeHandle = nil
    }

    private func rotateIfNeeded() throws {
        if writeHandle != nil {
            let isOversized = currentByteCount >= Self.maximumByteCount
            let isExpired = lastModifiedAt.map {
                Date.now.timeIntervalSince($0) >= Self.maximumAge
            } ?? false
            if isOversized || isExpired {
                closeHandle()
                currentByteCount = 0
                lastModifiedAt = nil
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        let values = try? fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate
        let isOversized = size >= Self.maximumByteCount
        let isExpired = modified.map {
            Date.now.timeIntervalSince($0) >= Self.maximumAge
        } ?? false
        if isOversized || isExpired {
            try? FileManager.default.removeItem(at: fileURL)
            currentByteCount = 0
            lastModifiedAt = nil
        } else if values != nil {
            currentByteCount = size
            lastModifiedAt = modified
        }
    }
}
