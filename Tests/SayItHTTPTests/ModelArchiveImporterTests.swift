import Foundation
import Testing
@testable import SayItHTTP

@Suite("Model archive import", .serialized)
struct ModelArchiveImporterTests {
    @Test("Root and nested model folders extract safely")
    func validArchives() async throws {
        for prefix in ["", "model/"] {
            let archive = FileManager.default.temporaryDirectory.appending(
                path: "SayItArchive-\(UUID().uuidString).tar"
            )
            defer { try? FileManager.default.removeItem(at: archive) }
            try makeTar(
                entries: [
                    (path: "\(prefix)config.json", type: 48, data: Data("{}".utf8)),
                    (
                        path: "\(prefix)weights/model.safetensors",
                        type: 48,
                        data: Data([1, 2, 3])
                    )
                ]
            ).write(to: archive)

            let extraction = try await ModelArchiveImporter().extract(archive)
            defer {
                try? FileManager.default.removeItem(
                    at: extraction.cleanupDirectory
                )
            }
            #expect(
                FileManager.default.fileExists(
                    atPath: extraction.modelDirectory
                        .appending(path: "config.json").path
                )
            )
            #expect(
                try Data(
                    contentsOf: extraction.modelDirectory.appending(
                        path: "weights/model.safetensors"
                    )
                ) == Data([1, 2, 3])
            )
        }
    }

    @Test("Archive validation rejects traversal, links, truncation, and bad layouts")
    func invalidArchives() async throws {
        let cases: [Data] = [
            Data([1, 2, 3]),
            try makeTar(
                entries: [
                    (path: "../escape", type: 48, data: Data())
                ]
            ),
            try makeTar(
                entries: [
                    (path: "/absolute", type: 48, data: Data())
                ]
            ),
            try makeTar(
                entries: [
                    (path: "link", type: 50, data: Data())
                ]
            ),
            try makeTar(
                entries: [
                    (path: "weights.bin", type: 48, data: Data())
                ]
            ),
            try makeTar(
                entries: [
                    (path: "one/config.json", type: 48, data: Data()),
                    (path: "two/config.json", type: 48, data: Data())
                ]
            )
        ]

        for data in cases {
            let archive = FileManager.default.temporaryDirectory.appending(
                path: "SayItArchive-\(UUID().uuidString).tar"
            )
            defer { try? FileManager.default.removeItem(at: archive) }
            try data.write(to: archive)
            await #expect(throws: (any Error).self) {
                _ = try await ModelArchiveImporter().extract(archive)
            }
        }
    }
}

private func makeTar(
    entries: [(path: String, type: UInt8, data: Data)]
) throws -> Data {
    var archive = Data()
    for entry in entries {
        var header = Data(repeating: 0, count: 512)
        writeTarString(entry.path, into: &header, range: 0..<100)
        let size = String(entry.data.count, radix: 8)
        writeTarString(
            String(repeating: "0", count: max(11 - size.count, 0))
                + size + "\0",
            into: &header,
            range: 124..<136
        )
        header[156] = entry.type
        archive.append(header)
        archive.append(entry.data)
        let padding = (512 - (entry.data.count % 512)) % 512
        archive.append(Data(repeating: 0, count: padding))
    }
    archive.append(Data(repeating: 0, count: 1_024))
    return archive
}

private func writeTarString(
    _ value: String,
    into data: inout Data,
    range: Range<Int>
) {
    for (offset, byte) in value.utf8.prefix(range.count).enumerated() {
        data[range.lowerBound + offset] = byte
    }
}
