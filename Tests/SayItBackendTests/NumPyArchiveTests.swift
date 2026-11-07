import Foundation
import Testing
@testable import SayItBackend

@Suite("NumPy archives")
struct NumPyArchiveTests {
    @Test("NumPy savez members are read through ZIP64 local headers")
    func readsSavezArchive() throws {
        let archive = try NumPyArchive(data: NumPyArchiveFixture.archive)

        let weights = try archive.array(named: "lq")
        #expect(weights.dtype == .int8)
        #expect(weights.shape == [2, 3])
        #expect(Array(weights.payload).map { Int8(bitPattern: $0) } == [1, -2, 3, -4, 5, -6])
        let half = try archive.array(named: "h")
        #expect(half.dtype == .float16)
        #expect(half.payload.withUnsafeBytes {
            Array($0.bindMemory(to: Float16.self))
        } == [0.5, -2])
    }

    @Test("A scalar Unicode member decodes as text")
    func decodesUnicodeScalar() throws {
        let tree = try NumPyArchive(data: NumPyArchiveFixture.archive).text(named: "__tree__")
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(tree.utf8)) as? [String: Any]
        )
        #expect(json["count"] as? Int == 7)
        let layer = (json["layers"] as? [[String: Any]])?.first
        #expect((layer?["q"] as? [String: String])?["@"] == "lq")
    }

    @Test("Compressed, truncated, missing, and mistyped members are rejected")
    func rejectsUnsupportedArchives() throws {
        #expect(throws: NumPyArchiveError.unsupportedMember("a.npy")) {
            try NumPyArchive(data: NumPyArchiveFixture.compressed)
        }
        #expect(throws: NumPyArchiveError.malformedArchive) {
            try NumPyArchive(data: Data(NumPyArchiveFixture.archive.prefix(400)))
        }
        let archive = try NumPyArchive(data: NumPyArchiveFixture.archive)
        #expect(throws: NumPyArchiveError.missingMember("missing")) {
            try archive.array(named: "missing")
        }
        #expect(throws: NumPyArchiveError.self) {
            try archive.array(named: "__tree__")
        }
        #expect(throws: NumPyArchiveError.self) {
            try archive.text(named: "lq")
        }
    }
}
