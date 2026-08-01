import Foundation
import Testing
@testable import SayItBackend

@Suite("Kitten voice archive conversion", .serialized)
struct KittenVoiceArchiveConverterTests {
    @Test("Stored NPZ voices are converted to safetensors")
    func convertsStoredNPZ() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "SayItKittenVoices-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let entryName = "expr-voice-2-f.npy"
        let npy = makeNPY(values: [0.25, -0.5, 1])
        try makeStoredZIP(name: entryName, contents: npy).write(
            to: directory.appending(path: "voices.npz")
        )

        try KittenVoiceArchiveConverter.prepareVoices(in: directory)
        let converted = directory.appending(path: "voices.safetensors")
        let size = try #require(
            converted.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        #expect(size > 0)

        try KittenVoiceArchiveConverter.prepareVoices(in: directory)
        #expect(
            try converted.resourceValues(forKeys: [.fileSizeKey]).fileSize
                == size
        )
    }

    private func makeNPY(values: [Float]) -> Data {
        var header = "{'descr': '<f4', 'fortran_order': False, "
            + "'shape': (\(values.count),), }"
        let prefixSize = 10
        let padding = (16 - (prefixSize + header.utf8.count + 1) % 16) % 16
        header += String(repeating: " ", count: padding) + "\n"

        var result = Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, 1, 0])
        append(UInt16(header.utf8.count), to: &result)
        result.append(contentsOf: header.utf8)
        for value in values {
            append(value.bitPattern, to: &result)
        }
        return result
    }

    private func makeStoredZIP(name: String, contents: Data) -> Data {
        var result = Data()
        append(UInt32(0x0403_4b50), to: &result)
        append(UInt16(20), to: &result)
        append(UInt16(0), to: &result)
        append(UInt16(0), to: &result)
        append(UInt16(0), to: &result)
        append(UInt16(0), to: &result)
        append(UInt32(0), to: &result)
        append(UInt32(contents.count), to: &result)
        append(UInt32(contents.count), to: &result)
        append(UInt16(name.utf8.count), to: &result)
        append(UInt16(0), to: &result)
        result.append(contentsOf: name.utf8)
        result.append(contentsOf: contents)
        return result
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }
}
