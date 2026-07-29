import Foundation

actor ModelArchiveImporter {
    struct Extraction: Sendable {
        let modelDirectory: URL
        let cleanupDirectory: URL
    }

    func extract(_ archive: URL) throws -> Extraction {
        let destination = FileManager.default.temporaryDirectory.appending(
            path: "SayIt-Model-Import-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        do {
            try extractTar(archive, into: destination)
            let modelDirectory = try findModelDirectory(in: destination)
            return Extraction(
                modelDirectory: modelDirectory,
                cleanupDirectory: destination
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func extractTar(_ archive: URL, into destination: URL) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer {
            try? input.close()
        }

        while true {
            guard let header = try input.read(upToCount: 512),
                  header.count == 512 else {
                throw ModelArchiveError.truncated
            }
            if header.allSatisfy({ $0 == 0 }) {
                return
            }

            let name = string(in: header, range: 0..<100)
            let prefix = string(in: header, range: 345..<500)
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let size = try octal(in: header, range: 124..<136)
            let type = header[156]
            let target = try safeTarget(
                for: path,
                in: destination
            )

            switch type {
            case 0, 48:
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard FileManager.default.createFile(
                    atPath: target.path,
                    contents: nil
                ) else {
                    throw ModelArchiveError.cannotCreateFile
                }
                let output = try FileHandle(forWritingTo: target)
                do {
                    try copy(
                        size: size,
                        from: input,
                        to: output
                    )
                    try output.close()
                } catch {
                    try? output.close()
                    throw error
                }
            case 53:
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
                try skip(size: size, in: input)
            default:
                throw ModelArchiveError.unsupportedEntry
            }

            let padding = (512 - (size % 512)) % 512
            if padding > 0 {
                try skip(size: padding, in: input)
            }
        }
    }

    private func copy(
        size: Int,
        from input: FileHandle,
        to output: FileHandle
    ) throws {
        var remaining = size
        while remaining > 0 {
            let count = min(remaining, 1_048_576)
            guard let data = try input.read(upToCount: count),
                  data.count == count else {
                throw ModelArchiveError.truncated
            }
            try output.write(contentsOf: data)
            remaining -= count
        }
    }

    private func skip(size: Int, in input: FileHandle) throws {
        var remaining = size
        while remaining > 0 {
            let count = min(remaining, 1_048_576)
            guard let data = try input.read(upToCount: count),
                  data.count == count else {
                throw ModelArchiveError.truncated
            }
            remaining -= count
        }
    }

    private func safeTarget(
        for path: String,
        in destination: URL
    ) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ModelArchiveError.unsafePath
        }
        let target = components.reduce(destination) {
            $0.appending(path: String($1))
        }.standardizedFileURL
        let allowedPrefix = destination.standardizedFileURL.path + "/"
        guard target.path.hasPrefix(allowedPrefix) else {
            throw ModelArchiveError.unsafePath
        }
        return target
    }

    private func findModelDirectory(in directory: URL) throws -> URL {
        if FileManager.default.fileExists(
            atPath: directory.appending(path: "config.json").path
        ) {
            return directory
        }
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var matches: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "config.json" {
                matches.append(url.deletingLastPathComponent())
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw ModelArchiveError.invalidModelLayout
        }
        return match
    }

    private func string(in data: Data, range: Range<Int>) -> String {
        let bytes = data[range].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func octal(in data: Data, range: Range<Int>) throws -> Int {
        let value = string(in: data, range: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Int(value, radix: 8), size >= 0 else {
            throw ModelArchiveError.invalidSize
        }
        return size
    }
}

private enum ModelArchiveError: LocalizedError {
    case truncated
    case invalidSize
    case unsafePath
    case unsupportedEntry
    case cannotCreateFile
    case invalidModelLayout

    var errorDescription: String? {
        switch self {
        case .truncated:
            "The TAR archive is truncated."
        case .invalidSize:
            "The TAR archive contains an invalid file size."
        case .unsafePath:
            "The TAR archive contains an unsafe path."
        case .unsupportedEntry:
            "The TAR archive contains links or unsupported entries."
        case .cannotCreateFile:
            "A model file could not be created."
        case .invalidModelLayout:
            "The TAR archive must contain exactly one model folder with config.json."
        }
    }
}
