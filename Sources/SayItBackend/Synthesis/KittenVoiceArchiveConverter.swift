import Foundation

import MLX

enum KittenVoiceArchiveConverter {
    private enum ArchiveError: LocalizedError {
        case corruptArchive
        case unsupportedArchive
        case emptyArchive

        var errorDescription: String? {
            switch self {
            case .corruptArchive:
                "The Kitten voice archive is corrupt."
            case .unsupportedArchive:
                "The Kitten voice archive uses an unsupported ZIP format."
            case .emptyArchive:
                "The Kitten voice archive contains no voices."
            }
        }
    }

    static func prepareVoices(in modelDirectory: URL) throws {
        let destination = modelDirectory.appending(path: "voices.safetensors")
        if isNonemptyFile(destination) {
            return
        }

        let archiveURL = modelDirectory.appending(path: "voices.npz")
        guard isNonemptyFile(archiveURL) else {
            return
        }

        let temporaryDirectory = modelDirectory.appending(
            path: ".kitten-voices-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let archive = try Data(contentsOf: archiveURL)
        let arrays = try loadStoredNPYEntries(
            from: archive,
            temporaryDirectory: temporaryDirectory
        )
        guard !arrays.isEmpty else {
            throw ArchiveError.emptyArchive
        }

        let converted = temporaryDirectory.appending(path: "voices.safetensors")
        try MLX.save(arrays: arrays, url: converted, stream: .cpu)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: converted, to: destination)
    }

    private static func loadStoredNPYEntries(
        from archive: Data,
        temporaryDirectory: URL
    ) throws -> [String: MLXArray] {
        let localFileSignature: UInt32 = 0x0403_4b50
        var offset = 0
        var arrays: [String: MLXArray] = [:]

        while offset + 4 <= archive.count {
            guard try readUInt32(archive, at: offset) == localFileSignature else {
                break
            }
            guard offset + 30 <= archive.count else {
                throw ArchiveError.corruptArchive
            }

            let flags = try readUInt16(archive, at: offset + 6)
            let compression = try readUInt16(archive, at: offset + 8)
            let compressed32 = try readUInt32(archive, at: offset + 18)
            let uncompressed32 = try readUInt32(archive, at: offset + 22)
            let nameLength = Int(try readUInt16(archive, at: offset + 26))
            let extraLength = Int(try readUInt16(archive, at: offset + 28))
            let nameStart = offset + 30
            let extraStart = nameStart + nameLength
            let dataStart = extraStart + extraLength
            guard dataStart <= archive.count,
                  let name = String(
                      data: archive[nameStart..<extraStart],
                      encoding: .utf8
                  ) else {
                throw ArchiveError.corruptArchive
            }

            guard flags & 0x0009 == 0, compression == 0 else {
                throw ArchiveError.unsupportedArchive
            }

            let sizes = try zip64Sizes(
                compressed32: compressed32,
                uncompressed32: uncompressed32,
                extra: archive[extraStart..<dataStart]
            )
            guard sizes.compressed == sizes.uncompressed,
                  sizes.compressed <= UInt64(Int.max) else {
                throw ArchiveError.unsupportedArchive
            }
            let dataEnd = dataStart + Int(sizes.compressed)
            guard dataEnd <= archive.count else {
                throw ArchiveError.corruptArchive
            }

            let filename = URL(fileURLWithPath: name).lastPathComponent
            if filename.hasSuffix(".npy"), filename == name {
                let entryURL = temporaryDirectory.appending(path: filename)
                try Data(archive[dataStart..<dataEnd]).write(
                    to: entryURL,
                    options: .atomic
                )
                let key = entryURL.deletingPathExtension().lastPathComponent
                arrays[key] = try MLX.loadArray(url: entryURL, stream: .cpu)
            }
            offset = dataEnd
        }
        return arrays
    }

    private static func zip64Sizes(
        compressed32: UInt32,
        uncompressed32: UInt32,
        extra: Data.SubSequence
    ) throws -> (compressed: UInt64, uncompressed: UInt64) {
        let sentinel = UInt32.max
        var compressed = UInt64(compressed32)
        var uncompressed = UInt64(uncompressed32)
        guard compressed32 == sentinel || uncompressed32 == sentinel else {
            return (compressed, uncompressed)
        }

        let data = Data(extra)
        var offset = 0
        while offset + 4 <= data.count {
            let identifier = try readUInt16(data, at: offset)
            let size = Int(try readUInt16(data, at: offset + 2))
            let payload = offset + 4
            guard payload + size <= data.count else {
                throw ArchiveError.corruptArchive
            }
            if identifier == 0x0001 {
                var cursor = payload
                if uncompressed32 == sentinel {
                    uncompressed = try readUInt64(data, at: cursor)
                    cursor += 8
                }
                if compressed32 == sentinel {
                    compressed = try readUInt64(data, at: cursor)
                }
                return (compressed, uncompressed)
            }
            offset = payload + size
        }
        throw ArchiveError.corruptArchive
    }

    private static func isNonemptyFile(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return size > 0
    }

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw ArchiveError.corruptArchive
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ArchiveError.corruptArchive
        }
        return (0..<4).reduce(UInt32.zero) {
            $0 | UInt32(data[offset + $1]) << UInt32($1 * 8)
        }
    }

    private static func readUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else {
            throw ArchiveError.corruptArchive
        }
        return (0..<8).reduce(UInt64.zero) {
            $0 | UInt64(data[offset + $1]) << UInt64($1 * 8)
        }
    }
}
