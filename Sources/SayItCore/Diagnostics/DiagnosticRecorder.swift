import Darwin
import Foundation

public actor DiagnosticRecorder {
    public static let maximumByteCount: Int64 = 10 * 1_024 * 1_024
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL
    private var recentEvents: [DiagnosticEvent] = []
    private var writeHandle: FileHandle?
    private var openFileInode: UInt64?
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
            if let handle = writeHandle, isCachedHandleValid() {
                do {
                    try handle.write(contentsOf: data)
                    currentByteCount += Int64(data.count)
                    lastModifiedAt = .now
                    return
                } catch {
                    closeHandle()
                }
            } else if writeHandle != nil {
                closeHandle()
                currentByteCount = 0
                lastModifiedAt = nil
            }
            let handle = try openAppendHandle()
            try handle.write(contentsOf: data)
            var fileStat = stat()
            if Darwin.fstat(handle.fileDescriptor, &fileStat) == 0 {
                currentByteCount = Int64(fileStat.st_size)
                openFileInode = fileStat.st_ino
            } else {
                currentByteCount += Int64(data.count)
            }
            lastModifiedAt = .now
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

    private func isCachedHandleValid() -> Bool {
        guard let openFileInode else { return false }
        var pathStat = Darwin.stat()
        guard Darwin.fstatat(AT_FDCWD, fileURL.path, &pathStat, 0) == 0 else {
            return false
        }
        return pathStat.st_ino == openFileInode
    }

    private func openAppendHandle() throws -> FileHandle {
        let fd = Darwin.open(
            fileURL.path,
            O_WRONLY | O_CREAT | O_APPEND,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        writeHandle = handle
        var fileStat = stat()
        if Darwin.fstat(fd, &fileStat) == 0 {
            openFileInode = fileStat.st_ino
        } else {
            openFileInode = nil
        }
        return handle
    }

    private func closeHandle() {
        try? writeHandle?.close()
        writeHandle = nil
        openFileInode = nil
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
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date
        let isOversized = size >= Self.maximumByteCount
        let isExpired = modified.map {
            Date.now.timeIntervalSince($0) >= Self.maximumAge
        } ?? false
        if isOversized || isExpired {
            try? FileManager.default.removeItem(at: fileURL)
            currentByteCount = 0
            lastModifiedAt = nil
        } else if attributes != nil {
            currentByteCount = size
            lastModifiedAt = modified
        }
    }
}
